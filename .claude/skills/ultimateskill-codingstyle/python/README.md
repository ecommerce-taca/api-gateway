# Python — quy ước chung

> ⚠️ **Stack Python CHƯA ĐƯỢC CHỐT.** Cecilia yêu cầu: *"để agent hỏi từng dự án"*.
> Với dự án mới, **bắt buộc hỏi** trước khi viết dòng code đầu tiên.
> Với dự án có sẵn, đọc `pyproject.toml` / `requirements.txt` để tự xác định, rồi xác nhận một dòng.

---

## 1. Câu hỏi bắt buộc ở đầu mỗi dự án Python mới

Sáu lựa chọn này ràng buộc lẫn nhau, nên hỏi **gộp một bảng kèm sẵn bộ khuyến nghị hoàn chỉnh**
(ngoại lệ của giới hạn 4 câu — xem `references/interview.md` nguyên tắc 2), để Cecilia duyệt cả gói
hoặc chỉ sửa vài dòng:

1. **Web framework**: FastAPI / Django + DRF / Flask / Litestar?
2. **Truy cập DB**: SQLAlchemy 2.0 (async hay sync?) / SQLModel / Django ORM / Tortoise?
3. **Migration**: Alembic / Django migrations?
4. **Quản lý package**: uv / Poetry / pip + requirements?
5. **Async hay sync?** — quyết định này lan ra toàn bộ codebase, không đổi giữa chừng được.
6. **Phiên bản Python tối thiểu?** (khuyến nghị 3.11+ cho `TaskGroup`, `Self`, exception group)

Gợi ý khuyến nghị mặc định nếu Cecilia không có ràng buộc:
**FastAPI + Pydantic v2 + SQLAlchemy 2.0 async + Alembic + uv + pytest** — nhưng vẫn phải hỏi, không tự áp.

---

## 2. Công cụ bắt buộc

```toml
# pyproject.toml
[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "C4", "SIM", "TCH", "ARG", "PTH", "RUF"]

[tool.mypy]
strict = true
warn_return_any = true
disallow_untyped_defs = true
# KHÔNG bật disallow_any_explicit: strict đã chặn Any ngầm định.
# Any tường minh vẫn cần cho vài chỗ ranh giới thật (parse JSON chưa validate,
# thư viện không có type stub) — ở đó bắt buộc kèm comment giải thích.
```

- **ruff** cho lint + format (thay black + isort + flake8).
- **mypy** hoặc **pyright** ở chế độ strict. Type hint không phải tuỳ chọn.
- **pytest** cho test.

---

## 3. Type hint — bắt buộc, đầy đủ

```python
# ❌ Không có type, payload là dict trần
def create_user(data):
    return repo.save(data)

# ✅ Type đầy đủ, dữ liệu vào là model có validate
async def create_user(self, cmd: CreateUserCommand) -> User:
    return await self._user_repo.save(User.create(cmd))
```

Quy tắc:

- Mọi tham số và giá trị trả về đều có type hint.
- **Không `Dict[str, Any]`** cho dữ liệu có cấu trúc — dùng Pydantic model hoặc dataclass.
- `Any` chỉ được dùng khi thật sự không thể biết, và phải có comment giải thích.
- Dùng cú pháp hiện đại: `list[str]`, `dict[str, int]`, `str | None` (không `Optional[str]`, không `List`).
- `Protocol` cho port/interface (duck typing có kiểm tra type), hoặc `ABC` khi cần ép implement.
- `Final`, `Literal`, `TypedDict`, `NewType` khi chúng làm rõ ý định.

---

## 4. Đặt tên file — snake_case + hậu tố vai trò

PEP8 dùng `_` thay `-`, nhưng **hậu tố vai trò giữ nguyên** để nhìn tên biết việc.

```
user_profile_service.py        user_profile_repository.py
user_profile_router.py         user_repository_port.py
create_user_dto.py             user_response_dto.py
user_entity.py                 user_mapper.py
kafka_event_publisher.py       app_exception.py
error_code.py                  test_user_profile_service.py
```

Định danh: `snake_case` cho hàm/biến, `PascalCase` cho class, `UPPER_SNAKE_CASE` cho hằng,
`_leading_underscore` cho private.

---

## 5. Pydantic — biên vào/ra

```python
class CreateUserDto(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)   # extra="forbid": loại field lạ

    email: EmailStr = Field(max_length=255)
    password: str = Field(min_length=8, max_length=128)
    role: UserRole
    display_name: str | None = Field(default=None, max_length=100)


class UserResponseDto(BaseModel):
    """Chỉ chứa field được phép lộ — password_hash không có mặt ở đây."""
    id: str
    email: EmailStr
    role: UserRole
    created_at: datetime
```

- `extra="forbid"` bắt buộc — chống mass-assignment.
- `frozen=True` cho DTO input (immutable).
- DTO request và DTO response **là hai class khác nhau**. Không tái dùng.
- Entity ORM không bao giờ được trả thẳng ra response.

---

## 6. Repository — ORM bị giấu hoàn toàn

```python
# domain/ports/user_repository_port.py — tầng TRONG
class UserRepositoryPort(Protocol):
    async def find_by_id(self, user_id: str) -> User | None: ...
    async def find_active_by_email(self, email: str) -> User | None: ...
    async def exists_by_email(self, email: str) -> bool: ...
    async def save(self, user: User) -> User: ...
```

```python
# infrastructure/persistence/user_sqlalchemy_repository.py — tầng NGOÀI
class UserSqlAlchemyRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_active_by_email(self, email: str) -> User | None:
        # select() chỉ được phép tồn tại bên trong repository
        stmt = select(UserOrm).where(UserOrm.email == email, UserOrm.status == UserStatus.ACTIVE)
        row = (await self._session.execute(stmt)).scalar_one_or_none()
        return UserMapper.to_domain(row) if row else None
```

Service **không** nhận `AsyncSession`, không thấy `select()`, không thấy `Query`.

### Transaction

Do tầng service quyết định, qua một unit-of-work bọc sẵn:

```python
async with self._uow:                        # bọc session, tự commit/rollback
    order = await self._order_repo.save(order)
    await self._outbox.enqueue(OrderCreatedEvent(order.id))
```

---

## 7. Exception

```python
# common/exceptions/app_exception.py
class AppException(Exception):
    def __init__(
        self,
        error_code: str,
        http_status: int,
        message: str,
        context: dict[str, object] | None = None,
    ) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.http_status = http_status
        self.message = message
        self.context = context or {}


class NotFoundException(AppException):
    def __init__(self, error_code: str, message: str, **context: object) -> None:
        super().__init__(error_code, 404, message, context)


class BusinessRuleException(AppException):
    def __init__(self, error_code: str, message: str, **context: object) -> None:
        super().__init__(error_code, 422, message, context)
```

- Không `raise Exception(...)` trần, không `raise HTTPException` trong service (service không biết HTTP).
- `error_code` lấy từ `common/errors/error_code.py`, không viết string literal rải rác.
- **Không** `except: pass`. Không `except Exception: return None` mà không log.
- Bắt exception cụ thể, không bắt `Exception` chung ở chỗ không cần.

---

## 8. Envelope + request_id (FastAPI)

```python
# middleware sinh request_id, lưu vào contextvars
request_id_ctx: ContextVar[str] = ContextVar("request_id", default="")

@app.middleware("http")
async def request_context_middleware(request: Request, call_next: Callable) -> Response:
    request_id = request.headers.get("x-request-id") or str(uuid7())
    token = request_id_ctx.set(request_id)
    try:
        response = await call_next(request)
        response.headers["X-Request-Id"] = request_id
        return response
    finally:
        request_id_ctx.reset(token)
```

```python
# exception handler — global handler duy nhất
@app.exception_handler(AppException)
async def app_exception_handler(request: Request, exc: AppException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.http_status,
        content=ApiResponse.fail(
            message=exc.message,
            error_code=exc.error_code,
            request_id=request_id_ctx.get(),
        ).model_dump(mode="json"),
    )
```

Envelope do một chỗ dựng ra (response model dùng chung hoặc middleware), không do từng route tự bọc.
Logger tự lấy `request_id` từ `contextvars` — **không truyền qua tham số hàm**.

---

## 9. Async

- Chọn async hay sync **một lần cho cả dự án**, không trộn.
- Trong hàm async, **không gọi hàm blocking** (`requests`, `time.sleep`, `psycopg2` sync,
  đọc file đồng bộ). Việc nặng CPU → `asyncio.to_thread` hoặc process pool.
- Chạy song song: `asyncio.gather` hoặc `asyncio.TaskGroup` (3.11+). Không `await` tuần tự
  trên danh sách độc lập.
- Mọi lời gọi ra ngoài có timeout: `asyncio.timeout(...)` hoặc timeout của client.
- Dùng `httpx.AsyncClient` tái sử dụng (một instance), không tạo client mới mỗi request.

---

## 10. Unit test — pytest

```python
class TestUserService:
    @pytest.fixture
    def user_repo(self) -> AsyncMock:
        return AsyncMock(spec=UserRepositoryPort)

    @pytest.fixture
    def service(self, user_repo: AsyncMock, hasher: AsyncMock) -> UserService:
        return UserService(user_repo=user_repo, hasher=hasher)

    async def test_should_reject_registration_when_email_exists(
        self, service: UserService, user_repo: AsyncMock
    ) -> None:
        # Arrange
        user_repo.exists_by_email.return_value = True

        # Act & Assert
        with pytest.raises(ConflictException) as exc:
            await service.register(CreateUserCommand(email="a@b.com", password="12345678"))
        assert exc.value.error_code == "EMAIL_ALREADY_EXISTS"
```

- Mock qua **port**, không mock `AsyncSession` hay `select()`.
- `AsyncMock(spec=...)` để mock đúng chữ ký, phát hiện gọi sai method.
- File `test_*.py` trong `tests/` phản chiếu cấu trúc `src/`.
- Không tự viết integration/e2e trừ khi Cecilia yêu cầu.

---

## 11. Những thứ thường làm sai với Python

| Sai | Đúng |
|---|---|
| Mutable default argument `def f(x=[])` | `def f(x: list[int] \| None = None)` |
| `except: pass` | Bắt exception cụ thể, log, hoặc để nó bay lên |
| Import vòng | Tách interface ra module riêng, dùng `TYPE_CHECKING` |
| Logic trong `__init__.py` | `__init__.py` chỉ để export |
| `from module import *` | Import tường minh |
| Dùng `dict` làm DTO | Pydantic model / dataclass |
| `datetime.now()` (naive) | `datetime.now(UTC)`, luôn timezone-aware |
| Đọc `os.environ` khắp nơi | Pydantic `BaseSettings` ở một chỗ |
| `print()` để debug | Logger có cấu trúc |
| Dùng `float` cho tiền | `Decimal` hoặc số nguyên đơn vị nhỏ nhất |
| Xâu chuỗi SQL bằng f-string | Tham số hoá, luôn luôn |
