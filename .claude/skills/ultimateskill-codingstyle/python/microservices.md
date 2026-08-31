# Python — kiến trúc MICROSERVICES

> Đọc `python/README.md` trước — **và nhớ hỏi stack Python + kênh giao tiếp trước khi làm gì**.
> Kênh: Kafka / RabbitMQ / NATS / gRPC / REST qua gateway / TCP.

---

## 1. Cấu trúc repo

```
project/
├── docker-compose.yml
├── libs/                                  # GIỮ MỎNG
│   ├── contracts/                         # event schema (Pydantic), .proto
│   ├── common/                            # envelope, AppException, error_code, request_context
│   └── observability/                     # logger, tracing, metric
│
└── services/
    ├── api-gateway/
    ├── user-service/
    │   ├── src/
    │   │   ├── main.py
    │   │   ├── container.py
    │   │   ├── modules/<feature>/         # cấu trúc như monolith
    │   │   └── infrastructure/
    │   │       ├── messaging/             # publisher, consumer adapter
    │   │       ├── clients/               # gọi service khác, bọc sau port
    │   │       ├── persistence/           # DB RIÊNG của service này
    │   │       └── config/
    │   ├── tests/
    │   ├── Dockerfile
    │   └── pyproject.toml                 # dependency RIÊNG từng service
    └── order-service/
```

**`libs/` là nơi microservices chết.** Chỉ chứa contract, type và tiện ích kỹ thuật thuần.
Không business logic, không entity dùng chung. Sửa một dòng phải deploy lại 5 service = monolith phân tán.

---

## 2. Luật bất di bất dịch

1. Mỗi service **một database riêng**. Không truy cập chéo.
2. **Không transaction phân tán.** Nhất quán cuối cùng qua event + saga.
3. **Mọi consumer idempotent.** Message sẽ được giao lại.
4. **Mọi lời gọi đồng bộ có timeout + circuit breaker.**
5. **`request_id`/`trace_id` xuyên suốt** mọi kênh.
6. **Event chỉ thêm field.** Breaking → `event_version` mới, chạy song song.
7. **Outbox pattern** cho ghi DB + phát event.

---

## 3. Chọn kênh giao tiếp

| Kênh | Dùng khi | Trong hệ Python | Cảnh báo |
|---|---|---|---|
| **Kafka** | Event stream, cần replay, nhiều consumer group, throughput cao | `aiokafka` (async) hoặc `confluent-kafka` (nhanh hơn, blocking) | Vận hành nặng; quá mức cho hệ nhỏ |
| **RabbitMQ / NATS** | Command/event, routing linh hoạt, hệ vừa và nhỏ | `aio-pika`; NATS qua `nats-py` (JetStream nếu cần bền) | Không replay được như Kafka |
| **gRPC** | Gọi đồng bộ nội bộ, độ trễ thấp, contract chặt | `grpcio` + `grpcio-tools` (dùng `grpc.aio` nếu app async) | Tạo coupling thời gian — service kia chết là mình chết |
| **REST qua gateway** | Client ngoài gọi vào; gọi nội bộ đơn giản | `httpx.AsyncClient` tái sử dụng một instance | Đừng dùng cho luồng cần bất đồng bộ |
| **TCP** | Nội bộ cùng cụm mạng, hệ nhỏ, cần kiểm soát protocol | Xem §3.1 | Tự viết framing/serialization; ít tooling |

**Nguyên tắc chọn:** mặc định **bất đồng bộ (event)**. Chỉ dùng đồng bộ khi bên gọi thật sự cần
kết quả ngay để trả lời client. Mỗi lời gọi đồng bộ là một điểm gãy thêm.

### 3.1 TCP trong hệ Python

Python không có "TCP transport" đóng gói sẵn như NestJS microservices. Nếu Cecilia chọn TCP,
**hỏi rõ ý định trước** — thường là một trong ba trường hợp:

| Ý định thật | Cách làm |
|---|---|
| "Gọi RPC nội bộ nhanh, không cần HTTP" | **Dùng gRPC** (chạy trên HTTP/2 qua TCP). Có contract, streaming, tooling sẵn. Đây là câu trả lời đúng trong hầu hết trường hợp |
| "Tích hợp thiết bị / hệ thống cũ nói protocol nhị phân qua TCP socket" | `asyncio.start_server` / `asyncio.open_connection` + codec riêng. Bắt buộc: length-prefix framing, timeout đọc/ghi, heartbeat, giới hạn kích thước frame |
| "Muốn nhẹ hơn HTTP giữa các service của mình" | Đo trước đã. Chênh lệch thường không đáng so với chi phí tự bảo trì protocol |

Nếu thật sự phải viết TCP client/server: **vẫn bọc sau port** như mọi kênh khác —
business code chỉ thấy `UserLookupPort`, không thấy `StreamReader`/`StreamWriter`.
Bắt buộc có: framing rõ ràng (**không** dựa vào ranh giới packet — TCP là luồng byte, không phải
luồng message), `asyncio.timeout` cho mọi thao tác đọc, reconnect có backoff,
và `request_id` nằm trong header của chính protocol đó.

---

## 4. Contract event — Pydantic là nguồn sự thật

```python
# libs/contracts/events/base_event.py
class DomainEvent(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    event_id: str = Field(default_factory=lambda: str(uuid7()))
    event_type: str
    event_version: int = 1
    occurred_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    request_id: str = ""
    producer: str


class OrderCreatedEvent(DomainEvent):
    event_type: Literal["order.order.created"] = "order.order.created"
    producer: Literal["order-service"] = "order-service"
    order_id: str
    customer_id: str
    total_amount_cents: int
    currency: str
```

- Payload chứa **đủ dữ liệu** để consumer làm việc — đừng bắt consumer gọi ngược lại producer.
- Chỉ thêm field mới **có default**. Xoá field / đổi kiểu = breaking.
- Số tiền là số nguyên cent, kèm `currency`. Không float.

---

## 5. Publisher — bọc sau port

```python
# libs/common/ports/event_publisher_port.py
class EventPublisherPort(Protocol):
    async def publish(self, event: DomainEvent) -> None: ...
    async def publish_all(self, events: Sequence[DomainEvent]) -> None: ...
```

```python
# infrastructure/messaging/kafka_event_publisher.py
class KafkaEventPublisher:
    def __init__(self, producer: AIOKafkaProducer, logger: AppLogger) -> None:
        self._producer = producer
        self._logger = logger

    async def publish(self, event: DomainEvent) -> None:
        await self._producer.send_and_wait(
            topic=event.event_type,
            key=event.aggregate_id.encode(),        # cùng aggregate → cùng partition → giữ thứ tự
            value=event.model_dump_json().encode(),
            headers=[
                ("x-request-id", request_id_ctx.get().encode()),
                ("x-event-id", event.event_id.encode()),
            ],
        )
```

Business code chỉ biết `EventPublisherPort`. Đổi Kafka → RabbitMQ chỉ thay adapter.

---

## 6. Outbox pattern

```python
# B1 — trong transaction: ghi dữ liệu + ghi outbox cùng lúc
async with self._uow:
    order = await self._order_repo.save(order)
    await self._outbox_repo.enqueue(OrderCreatedEvent(order_id=order.id, ...))

# B2 — worker riêng đọc outbox chưa gửi → publish → đánh dấu published_at
# At-least-once → consumer PHẢI idempotent
```

Bảng outbox: `id, aggregate_id, event_type, event_version, payload, request_id, created_at, published_at, retry_count`.

---

## 7. Consumer — idempotent, có DLQ

```python
class OrderCreatedConsumer:
    async def handle(self, raw: bytes, headers: dict[str, bytes]) -> None:
        request_id = headers.get("x-request-id", b"").decode()
        token = request_id_ctx.set(request_id)          # nối trace với luồng gốc
        try:
            event = OrderCreatedEvent.model_validate_json(raw)

            # Chống xử lý lặp
            if await self._processed.exists(event.event_id):
                self._logger.debug("event already processed", event_id=event.event_id)
                return

            async with self._uow:
                await self._use_case.execute(event)
                await self._processed.mark(event.event_id)   # cùng transaction với việc xử lý

        except ValidationError:
            # Payload sai schema — retry vô ích, đẩy DLQ ngay
            await self._dlq.send(raw, reason="schema_validation_failed")
        finally:
            request_id_ctx.reset(token)
```

- Bảng `processed_events` (khoá chính `event_id`), đánh dấu **cùng transaction**.
- DLQ + metric số message trong DLQ. DLQ không ai xem là DLQ vô nghĩa.
- Retry có backoff, giới hạn lần. Lỗi không phục hồi được → DLQ ngay.
- Đo consumer lag, cảnh báo khi tăng.
- **Không commit offset trước khi xử lý xong.** `enable_auto_commit=False`.

---

## 8. Gọi đồng bộ giữa service

```python
# domain/ports/user_lookup_port.py
class UserLookupPort(Protocol):
    async def get_basic_info(self, user_id: str) -> UserBasicInfo | None: ...
```

```python
# infrastructure/clients/user_service_client.py
class UserServiceClient:
    def __init__(self, http: httpx.AsyncClient, breaker: CircuitBreaker) -> None:
        self._http = http
        self._breaker = breaker

    async def get_basic_info(self, user_id: str) -> UserBasicInfo | None:
        try:
            async with self._breaker:                       # circuit breaker
                res = await self._http.get(
                    f"/internal/v1/users/{user_id}",
                    timeout=3.0,                            # BẮT BUỘC
                    headers={"x-request-id": request_id_ctx.get()},
                )
            if res.status_code == 404:
                return None
            res.raise_for_status()
            return UserBasicInfo.model_validate(res.json()["data"])
        except (httpx.HTTPError, CircuitBreakerOpen) as err:
            # Dịch lỗi hạ tầng sang exception của mình
            raise ExternalServiceException(
                "USER_SERVICE_UNAVAILABLE", "user-service không phản hồi"
            ) from err
```

- `httpx.AsyncClient` **tái sử dụng một instance** cho cả vòng đời app, không tạo mới mỗi request.
- Timeout trên mọi lời gọi.
- Không gọi chuỗi sâu A→B→C→D. Không gọi service khác trong transaction DB.

---

## 9. gRPC (nếu chọn)

- `.proto` trong `libs/contracts/proto/`, sinh code lúc build (`grpcio-tools`), **không commit code sinh ra**.
- Chỉ thêm field với số mới. Số đã bỏ đánh `reserved`, không tái dùng.
- Truyền `request_id` qua metadata.
- Vẫn bọc client sau port — business code không import `grpc`.
- Interceptor để log + gắn trace, không rắc code đó vào từng call.

---

## 10. Saga

Choreography cho luồng đơn giản, orchestration cho luồng phức tạp. Mỗi bước **phải có hành động bù trừ**.

```
order.created
  ├─ inventory-service: reserve → ok: inventory.reserved | fail: inventory.failed → HỦY ĐƠN
  └─ payment-service:   charge  → ok: payment.succeeded  | fail: payment.failed   → NHẢ HÀNG
```

- Trạng thái saga lưu trong bảng, không giữ trong bộ nhớ (process chết là mất).
- Có timeout cho saga treo.
- Vẽ luồng và **hỏi Cecilia duyệt trước khi code**.

---

## 11. Cấu hình & khởi động

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="forbid")

    service_name: str
    database_url: PostgresDsn
    kafka_brokers: list[str]
    jwt_secret: SecretStr = Field(min_length=32)   # không có default cho secret
    http_timeout_seconds: float = 3.0
```

- Validate lúc boot, thiếu là **chết ngay**, không chạy tiếp.
- `SecretStr` cho secret — tránh lộ khi in log hay repr.
- `os.environ` chỉ xuất hiện ở đây.

## 12. Vòng đời & graceful shutdown

```python
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    await container.start()          # kết nối DB, producer, consumer
    yield
    # SIGTERM → ngừng nhận việc mới → xử nốt → đóng kết nối
    await container.stop()
```

Thiếu graceful shutdown = mất message đang xử lý mỗi lần deploy.

---

## 13. Observability

- OpenTelemetry bắt buộc. `trace_id` = `request_id`.
- Log JSON (structlog), luôn có `service`, `request_id`, `trace_id`, `event_id` khi xử lý message.
- Metric: request rate/latency/error, consumer lag, kích thước DLQ, tỉ lệ breaker mở, độ trễ gọi ngoài.
- `/health` (liveness, **không** phụ thuộc DB) và `/health/ready` (readiness, kiểm DB + broker).

---

## 14. Checklist riêng

- [ ] Đã **hỏi và chốt stack Python + kênh giao tiếp**
- [ ] Mỗi service DB riêng, `pyproject.toml` riêng
- [ ] `libs/` không chứa business logic
- [ ] Publisher/consumer/client bọc sau port, business code không import `aiokafka`/`grpc`/`httpx`
- [ ] Consumer idempotent, có `processed_events`, đánh dấu cùng transaction
- [ ] `enable_auto_commit=False`, commit offset sau khi xử lý xong
- [ ] Có DLQ + retry backoff + metric DLQ
- [ ] Outbox pattern cho ghi DB + phát event
- [ ] Mọi lời gọi đồng bộ có timeout + circuit breaker + fallback
- [ ] `request_id` truyền qua HTTP header, message header, gRPC metadata
- [ ] Event có đủ `event_id`, `event_type`, `event_version`, `occurred_at`, `request_id`, `producer`
- [ ] Saga có hành động bù trừ, trạng thái lưu bền, có timeout
- [ ] Graceful shutdown xử lý `SIGTERM` đúng
- [ ] `httpx.AsyncClient` tái sử dụng, không tạo mới mỗi request
