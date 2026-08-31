# Python — kiến trúc KHÔNG microservices (modular monolith)

> Đọc `python/README.md` trước — **và nhớ hỏi stack Python trước khi làm gì**.

---

## 1. Cấu trúc — Mức 1: Modular theo feature *(mặc định)*

```
src/
├── main.py                          # khởi tạo app, đăng ký middleware/handler
├── container.py                     # DI wiring (dependency-injector hoặc factory thủ công)
│
├── modules/
│   ├── user/
│   │   ├── __init__.py
│   │   ├── user_router.py           # FastAPI router — mỏng
│   │   ├── user_service.py          # business logic
│   │   ├── user_repository_port.py  # Protocol/ABC — port
│   │   ├── user_sqlalchemy_repository.py
│   │   ├── user_mapper.py
│   │   ├── dto/
│   │   │   ├── create_user_dto.py
│   │   │   └── user_response_dto.py
│   │   └── entities/
│   │       └── user_entity.py
│   └── order/ ...
│
├── common/
│   ├── exceptions/     app_exception.py
│   ├── errors/         error_code.py       # catalog errorCode duy nhất
│   ├── dto/            api_response.py, paged.py
│   ├── context/        request_context.py  # contextvars
│   └── deps/           dependency chung của FastAPI
│
└── infrastructure/
    ├── config/         settings.py         # Pydantic BaseSettings, validate lúc boot
    ├── logging/        logger_port.py + structlog_logger.py
    ├── database/       session.py, base_entity.py, unit_of_work.py, migrations/
    ├── cache/          cache_port.py + redis_cache_adapter.py
    ├── http/           http_client_port.py + httpx_client_adapter.py
    └── storage/        file_storage_port.py + s3_storage_adapter.py

tests/
└── modules/user/test_user_service.py       # phản chiếu cấu trúc src/
```

## 2. Cấu trúc — Mức 3: Clean/Hexagonal *(nghiệp vụ phức tạp)*

Chỉ dựng sau khi đánh giá theo `references/core-principles.md` §2 **và Cecilia đồng ý**.

```
src/modules/order/
├── domain/
│   ├── entities/order_entity.py         # dataclass thuần, KHÔNG SQLAlchemy
│   ├── value_objects/money.py
│   ├── services/pricing_domain_service.py
│   ├── events/order_created_event.py
│   └── ports/order_repository_port.py, payment_gateway_port.py
├── application/
│   ├── use_cases/create_order_use_case.py
│   └── commands/create_order_command.py
├── infrastructure/
│   ├── persistence/order_orm.py, order_sqlalchemy_repository.py, order_mapper.py
│   └── gateways/stripe_payment_gateway.py
└── presentation/
    ├── order_router.py
    └── dto/create_order_dto.py, order_response_dto.py
```

`domain/entities/order_entity.py` là dataclass thuần — **không** `Mapped[]`, không `Base`.
Model SQLAlchemy nằm ở `infrastructure/persistence/order_orm.py`. Nối bằng mapper.

---

## 3. Ranh giới module — nghiêm ngặt

1. Module A **không import** service/repository/entity của module B.
2. Giao tiếp qua **facade port** (module B định nghĩa một Protocol hẹp) hoặc **event nội bộ**.
3. **Không JOIN** qua bảng của module khác. Cần dữ liệu → gọi facade.
4. `common/` và `infrastructure/` **không được chứa nghiệp vụ** của module nào.

```python
# ❌ Coupling chặt
class OrderService:
    def __init__(self, user_service: UserService) -> None: ...

# ✅ Qua facade hẹp
class UserFacadePort(Protocol):
    async def get_basic_info(self, user_id: str) -> UserBasicInfo | None: ...
    async def is_active(self, user_id: str) -> bool: ...

class OrderService:
    def __init__(self, user_facade: UserFacadePort) -> None: ...
```

Kiểm tra tự động ranh giới: cấu hình `ruff` `flake8-tidy-imports` với `banned-api`,
hoặc thêm `import-linter` với contract "modules độc lập".

---

## 4. Dependency Injection

Không dùng biến global, không import instance sẵn.

**FastAPI**: dùng `Depends` với factory function, khai báo ở `common/deps/`.

```python
def get_user_service(
    session: AsyncSession = Depends(get_session),
    logger: AppLogger = Depends(get_logger),
) -> UserService:
    return UserService(
        user_repo=UserSqlAlchemyRepository(session),
        hasher=Argon2PasswordHasher(),
        logger=logger,
    )
```

Router chỉ nhận service qua `Depends`, không tự dựng.

**Dự án lớn**: dùng `dependency-injector` với container khai báo tường minh ở `container.py`.

---

## 5. Router — mỏng, không logic

```python
router = APIRouter(prefix="/v1/users", tags=["users"])

@router.post("", status_code=status.HTTP_201_CREATED, response_model=ApiResponse[UserResponseDto])
async def create_user(
    dto: CreateUserDto,
    service: UserService = Depends(get_user_service),
) -> UserResponseDto:
    # Trả DTO thuần. Middleware/route_class bọc envelope, exception handler toàn cục lo phần lỗi.
    user = await service.register(dto.to_command())
    return UserResponseDto.from_domain(user)
```

Router **không** chứa: business rule, truy vấn DB, try/except để format lỗi,
và **không tự dựng envelope** — đó là việc của một chỗ dùng chung.

FastAPI không có interceptor như Nest, nên dùng một trong hai cách (chọn một, dùng nhất quán cả dự án):

```python
# Cách A — custom APIRoute class: bọc envelope tập trung, giữ được type gợi ý ở router
class EnvelopeRoute(APIRoute):
    def get_route_handler(self) -> Callable:
        original = super().get_route_handler()

        async def wrapper(request: Request) -> Response:
            response = await original(request)
            body = json.loads(response.body)
            return JSONResponse(
                status_code=response.status_code,
                content=ApiResponse.ok(body, request_id=request_id_ctx.get()).model_dump(mode="json"),
            )
        return wrapper

router = APIRouter(prefix="/v1/users", route_class=EnvelopeRoute)
```

```python
# Cách B — middleware bọc mọi response JSON 2xx (đơn giản hơn, nhưng khó loại trừ route đặc biệt)
```

---

## 6. Transaction & Unit of Work

```python
class UnitOfWork:
    """Bọc session để service không phải biết SQLAlchemy."""
    async def __aenter__(self) -> "UnitOfWork": ...
    async def __aexit__(self, *exc: object) -> None: ...   # commit nếu không lỗi, rollback nếu lỗi
```

```python
async def create_order(self, cmd: CreateOrderCommand) -> Order:
    async with self._uow:
        order = await self._order_repo.save(Order.create(cmd))
        await self._inventory_repo.reserve(cmd.items)
        # Event vào outbox trong transaction, phát sau khi commit
        await self._outbox.enqueue(OrderCreatedEvent(order.id))
        return order
```

- Phạm vi transaction do **service** quyết định, không do repository.
- Transaction ngắn. **Không gọi API ngoài bên trong transaction.**
- Gửi mail/webhook/event: qua outbox, phát sau commit.

---

## 7. Database & migration

- **Alembic bắt buộc** (hoặc Django migrations nếu dùng Django). Không `create_all()` ở bất kỳ môi trường nào.
- Tên revision mô tả rõ: `add_idempotency_key_to_orders`.
- `downgrade()` phải chạy được thật.
- Schema Postgres chia theo module nếu được (`user.users`, `order.orders`) — ranh giới rõ, tách dễ.
- Index cho mọi khoá ngoại và cột lọc/sắp xếp thường xuyên.
- Tiền: `Numeric(19, 4)` hoặc số nguyên đơn vị nhỏ nhất. **Không `Float`.**
- Thời gian: `TIMESTAMP WITH TIME ZONE`, lưu UTC.
- Chống N+1: `selectinload` / `joinedload` tường minh trong repository.

---

## 8. Background job trong monolith

- Việc ngắn, không quan trọng → `BackgroundTasks` của FastAPI.
- Việc quan trọng, cần retry, cần theo dõi → hàng đợi thật (Celery / ARQ / Dramatiq) —
  **nhưng phải hỏi trước khi thêm**, đây là dependency mới.
- Task cũng phải idempotent — nó sẽ chạy lại.
- Task nhận **id**, không nhận cả object (object serialize được lúc đẩy vào queue có thể đã cũ lúc chạy).

---

## 9. Khi nào NÊN tách microservices

Giống `nestjs/monolith.md` §7: chỉ tách khi có nhu cầu scale độc lập, nhiều team giẫm chân,
công nghệ khác biệt, hoặc SLA khác nhau rõ rệt. **Chưa có → giữ modular monolith.**

Với Python có một lý do đặc thù đáng cân nhắc: phần nặng CPU (ML, xử lý ảnh) bị GIL cản
→ tách ra worker/service riêng là hợp lý, kể cả khi phần còn lại vẫn là monolith.

---

## 10. Checklist riêng

- [ ] Đã **hỏi và chốt stack Python** trước khi code
- [ ] Không module nào import internal của module khác
- [ ] `common/`, `infrastructure/` không chứa nghiệp vụ
- [ ] Service không nhận `AsyncSession`, không thấy `select()`
- [ ] Có Alembic migration, `downgrade()` chạy được
- [ ] Transaction do service quyết định, ngắn, không gọi API ngoài bên trong
- [ ] `mypy --strict` pass, `ruff check` pass
- [ ] Không `Dict[str, Any]` cho dữ liệu có cấu trúc
- [ ] `datetime` luôn timezone-aware (UTC)
- [ ] Tiền không dùng `float`
- [ ] Không mutable default argument
- [ ] Không blocking call trong hàm async
