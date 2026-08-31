# Java — kiến trúc MICROSERVICES

> Đọc `java/README.md` trước — **và nhớ hỏi stack Java + kênh giao tiếp trước khi làm gì**.
> Kênh: Kafka / RabbitMQ / NATS / gRPC / REST qua gateway / TCP.

---

## 1. Cấu trúc repo

```
project/
├── docker-compose.yml
├── pom.xml                                 # parent POM (multi-module) — nếu dùng Maven
├── libs/                                   # GIỮ MỎNG
│   ├── contracts/                          # event schema (record), .proto, DTO liên service
│   ├── common/                             # ApiResponse, AppException, ErrorCode, RequestContext
│   └── observability/                      # AppLogger, tracing config
│
└── services/
    ├── api-gateway/
    ├── user-service/
    │   ├── src/main/java/.../
    │   │   ├── modules/<feature>/           # cấu trúc như monolith
    │   │   └── infrastructure/
    │   │       ├── messaging/               # publisher, consumer adapter
    │   │       ├── client/                  # gọi service khác, bọc sau port
    │   │       ├── persistence/             # DB RIÊNG của service này
    │   │       └── config/
    │   ├── src/main/resources/db/migration/
    │   ├── Dockerfile
    │   └── pom.xml
    └── order-service/
```

**`libs/` là nơi microservices chết.** Chỉ chứa contract, type, tiện ích kỹ thuật thuần.
Không business logic, không entity dùng chung. Không đưa `libs/common` thành nơi chứa
`BaseService` với logic nghiệp vụ — sửa một dòng phải deploy lại toàn hệ.

---

## 2. Luật bất di bất dịch

1. Mỗi service **một database riêng**. Không truy cập chéo.
2. **Không transaction phân tán, không JTA/2PC.** Nhất quán cuối cùng qua event + saga.
3. **Mọi consumer idempotent.**
4. **Mọi lời gọi đồng bộ có timeout + circuit breaker (Resilience4j).**
5. **`requestId`/`traceId` xuyên suốt** mọi kênh.
6. **Event chỉ thêm field.** Breaking → `eventVersion` mới, chạy song song.
7. **Outbox pattern** cho ghi DB + phát event.

---

## 3. Chọn kênh giao tiếp

| Kênh | Dùng khi | Trong hệ Java | Cảnh báo |
|---|---|---|---|
| **Kafka** | Event stream, cần replay, nhiều consumer group, throughput cao | `spring-kafka` + Schema Registry (Avro) nếu cần kiểm tra tương thích ở CI | Vận hành nặng; quá mức cho hệ nhỏ |
| **RabbitMQ / NATS** | Command/event, routing linh hoạt, hệ vừa và nhỏ | `spring-amqp`; NATS qua `jnats` | Không replay được như Kafka |
| **gRPC** | Gọi đồng bộ nội bộ, độ trễ thấp, contract chặt | `grpc-spring-boot-starter` + `protobuf-maven-plugin` | Tạo coupling thời gian — service kia chết là mình chết |
| **REST qua gateway** | Client ngoài gọi vào; gọi nội bộ đơn giản | `RestClient` (Boot 3.2+) hoặc `WebClient` | Đừng dùng cho luồng cần bất đồng bộ |
| **TCP** | Nội bộ cùng cụm mạng, hệ nhỏ, cần kiểm soát protocol | Xem §3.1 | Tự viết framing/serialization; ít tooling |

**Nguyên tắc chọn:** mặc định **bất đồng bộ (event)**. Chỉ dùng đồng bộ khi bên gọi thật sự cần
kết quả ngay để trả lời client. Mỗi lời gọi đồng bộ là một điểm gãy thêm.

### 3.1 TCP trong hệ Java

Java không có sẵn "TCP transport" gói gọn như NestJS microservices. Nếu Cecilia chọn TCP,
**hỏi rõ ý định trước** — thường một trong ba trường hợp sau:

| Ý định thật | Cách làm |
|---|---|
| "Gọi RPC nội bộ nhanh, không cần HTTP" | **Dùng gRPC** (chạy trên HTTP/2 qua TCP). Được contract, streaming, tooling sẵn. Đây là câu trả lời đúng trong hầu hết trường hợp |
| "Tích hợp thiết bị / hệ thống cũ nói protocol nhị phân qua TCP socket" | Netty (`spring-boot-starter-webflux` đã kéo Netty về) + codec riêng. Bắt buộc: length-prefix framing, timeout đọc/ghi, heartbeat, giới hạn kích thước frame |
| "Muốn nhẹ hơn HTTP giữa các service của mình" | Đo trước đã. Chênh lệch thường không đáng so với chi phí tự bảo trì protocol |

Nếu thật sự phải viết TCP client/server: **vẫn bọc sau port** như mọi kênh khác —
business code chỉ thấy `UserLookup`, không thấy `Channel`, `ByteBuf` hay `Socket`.
Bắt buộc có: framing rõ ràng (không dựa vào ranh giới packet), timeout, reconnect có backoff,
và `requestId` nằm trong header của chính protocol đó.

---

## 4. Contract event — `record` là nguồn sự thật

```java
// libs/contracts/event/DomainEvent.java
public interface DomainEvent {
    String eventId();
    String eventType();
    int eventVersion();
    Instant occurredAt();
    String requestId();
    String producer();
    String aggregateId();
}

public record OrderCreatedEvent(
    String eventId,
    Instant occurredAt,
    String requestId,
    String orderId,
    String customerId,
    long totalAmountCents,
    String currency
) implements DomainEvent {
    @Override public String eventType()   { return "order.order.created"; }
    @Override public int    eventVersion(){ return 1; }
    @Override public String producer()    { return "order-service"; }
    @Override public String aggregateId() { return orderId; }
}
```

- Payload chứa **đủ dữ liệu** để consumer làm việc.
- Chỉ thêm field mới. Xoá field / đổi kiểu = breaking.
- Tiền là `long` cent + `currency`. Không `double`.
- Nếu dùng Avro/Protobuf + Schema Registry: bật kiểm tra tương thích **BACKWARD** ở CI.

---

## 5. Publisher — bọc sau port

```java
// domain/port/EventPublisher.java — tầng TRONG
public interface EventPublisher {
    void publish(DomainEvent event);
    void publishAll(List<DomainEvent> events);
}
```

```java
// infrastructure/messaging/KafkaEventPublisher.java — tầng NGOÀI
@Component
@RequiredArgsConstructor
public class KafkaEventPublisher implements EventPublisher {

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final ObjectMapper objectMapper;
    private final AppLogger logger;

    @Override
    public void publish(DomainEvent event) {
        try {
            var record = new ProducerRecord<>(
                event.eventType(),
                event.aggregateId(),                       // cùng aggregate → cùng partition
                objectMapper.writeValueAsString(event)
            );
            record.headers().add("x-request-id", RequestContext.requestId().getBytes(UTF_8));
            record.headers().add("x-event-id", event.eventId().getBytes(UTF_8));
            kafkaTemplate.send(record).get(5, TimeUnit.SECONDS);   // timeout bắt buộc
        } catch (Exception e) {
            throw new ExternalServiceException(ErrorCode.EVENT_PUBLISH_FAILED,
                                               "Không publish được event", Map.of());
        }
    }
}
```

Business code chỉ biết `EventPublisher`. Đổi Kafka → RabbitMQ chỉ thay adapter + config.

---

## 6. Outbox pattern

```java
@Transactional
public Order createOrder(CreateOrderCommand cmd) {
    Order order = orderRepository.save(Order.create(cmd));
    // Ghi outbox trong CÙNG transaction với dữ liệu nghiệp vụ
    outboxRepository.enqueue(new OrderCreatedEvent(...));
    return order;
}
```

```java
// Worker riêng: đọc outbox chưa gửi → publish → đánh dấu publishedAt
@Scheduled(fixedDelay = 1000)
@SchedulerLock(name = "outboxPublisher")   // ShedLock — nhiều replica không chạy trùng
public void publishPending() { ... }
```

Bảng outbox: `id, aggregate_id, event_type, event_version, payload, request_id, created_at, published_at, retry_count`.
At-least-once → consumer **phải** idempotent.

---

## 7. Consumer — idempotent, có DLQ

```java
@Component
@RequiredArgsConstructor
public class OrderCreatedConsumer {

    @KafkaListener(topics = "order.order.created", groupId = "inventory-service")
    @Transactional
    public void handle(ConsumerRecord<String, String> record, Acknowledgment ack) {
        String requestId = header(record, "x-request-id");
        MDC.put("requestId", requestId);              // nối trace với luồng gốc
        try {
            OrderCreatedEvent event = objectMapper.readValue(record.value(), OrderCreatedEvent.class);

            // Chống xử lý lặp
            if (processedEventRepository.exists(event.eventId())) {
                logger.debug("event already processed", Map.of("eventId", event.eventId()));
                ack.acknowledge();
                return;
            }

            useCase.execute(event);
            processedEventRepository.mark(event.eventId());   // CÙNG transaction với việc xử lý
            ack.acknowledge();                                 // commit offset SAU khi xử lý xong

        } catch (JsonProcessingException e) {
            // Payload sai schema — retry vô ích, đẩy DLQ ngay
            deadLetterPublisher.send(record, "schema_validation_failed");
            ack.acknowledge();
        } finally {
            MDC.clear();
        }
    }
}
```

Bắt buộc:

- `enable-auto-commit: false`, `ack-mode: MANUAL`. Commit offset **sau** khi xử lý xong.
- Bảng `processed_events` (khoá chính `eventId`), đánh dấu **cùng transaction**.
- `DefaultErrorHandler` + `DeadLetterPublishingRecoverer` với backoff, giới hạn lần.
- Metric consumer lag và kích thước DLQ. DLQ không ai xem là vô nghĩa.
- Lỗi không phục hồi được → DLQ ngay, đừng retry.

---

## 8. Gọi đồng bộ giữa service

```java
// domain/port/UserLookup.java
public interface UserLookup {
    Optional<UserBasicInfo> getBasicInfo(UserId userId);
}
```

```java
// infrastructure/client/UserServiceClient.java
@Component
@RequiredArgsConstructor
public class UserServiceClient implements UserLookup {

    private final RestClient restClient;   // đã cấu hình timeout + interceptor gắn X-Request-Id

    @Override
    @CircuitBreaker(name = "user-service", fallbackMethod = "fallbackBasicInfo")
    @Retry(name = "user-service")          // chỉ retry thao tác idempotent (GET)
    public Optional<UserBasicInfo> getBasicInfo(UserId userId) {
        try {
            var res = restClient.get()
                .uri("/internal/v1/users/{id}", userId.value())
                .retrieve()
                .body(new ParameterizedTypeReference<ApiResponse<UserBasicInfo>>() {});
            return Optional.ofNullable(res).map(ApiResponse::data);
        } catch (HttpClientErrorException.NotFound e) {
            return Optional.empty();
        }
    }

    // Fallback rõ ràng khi mạch mở — không để lỗi hạ tầng trôi lên service
    private Optional<UserBasicInfo> fallbackBasicInfo(UserId userId, Throwable t) {
        throw new ExternalServiceException(ErrorCode.USER_SERVICE_UNAVAILABLE,
                                           "user-service không phản hồi", Map.of());
    }
}
```

Cấu hình timeout **bắt buộc** trên `RestClient`/`WebClient` (connect + read).
Không gọi chuỗi sâu A→B→C→D. **Không gọi service khác bên trong `@Transactional`.**

---

## 9. gRPC (nếu chọn)

- `.proto` trong `libs/contracts/proto/`, sinh code lúc build (`protobuf-maven-plugin`),
  **không commit code sinh ra**.
- Chỉ thêm field với số mới. Số đã bỏ đánh `reserved`.
- `requestId` truyền qua metadata; dùng `ServerInterceptor`/`ClientInterceptor` để gắn tự động
  và đưa vào MDC — không rắc code đó vào từng call.
- Vẫn bọc client sau port — business code không import `io.grpc`.

---

## 10. Saga

Choreography cho luồng đơn giản, orchestration cho luồng phức tạp.
**Mỗi bước phải có hành động bù trừ.**

```
order.created
  ├─ inventory-service: reserve → ok: inventory.reserved | fail: inventory.failed → HỦY ĐƠN
  └─ payment-service:   charge  → ok: payment.succeeded  | fail: payment.failed   → NHẢ HÀNG
```

- Trạng thái saga lưu trong bảng, không giữ trong bộ nhớ.
- Có timeout cho saga treo.
- Vẽ luồng và **hỏi Cecilia duyệt trước khi code**.

---

## 11. Cấu hình

```java
@ConfigurationProperties(prefix = "app")
@Validated
public record AppProperties(
    @NotBlank String serviceName,
    @NotNull @Valid KafkaProperties kafka,
    @NotBlank @Size(min = 32) String jwtSecret,     // không có default cho secret
    @Positive int httpTimeoutMs
) {}
```

- `@Validated` → thiếu/sai config là **chết lúc boot**, không chạy tiếp.
- `@Value` rải rác bị cấm — chỉ dùng `@ConfigurationProperties`.
- Secret từ env/vault, không nằm trong `application.yml` commit lên git.

---

## 12. Graceful shutdown

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
  kafka:
    listener:
      ack-mode: MANUAL
```

SIGTERM → ngừng nhận request/message mới → xử nốt việc đang chạy → đóng kết nối → thoát.
Thiếu graceful shutdown = mất message mỗi lần deploy.

---

## 13. Observability

- Micrometer + OpenTelemetry. `traceId` = `requestId`.
- Log JSON (logback + `logstash-logback-encoder`), luôn có `service`, `requestId`, `traceId`,
  `eventId` khi xử lý message.
- ⚠️ **MDC không tự propagate** sang `@Async`, `@KafkaListener` thread, `CompletableFuture` —
  phải gắn thủ công (`TaskDecorator`, đặt MDC đầu listener, clear trong `finally`).
- Actuator: `/actuator/health/liveness` (**không** phụ thuộc DB) và `/actuator/health/readiness`
  (kiểm DB + Kafka). Chỉ expose endpoint cần thiết, có bảo vệ.
- Metric: request rate/latency/error, consumer lag, DLQ size, tỉ lệ breaker mở, độ trễ gọi ngoài.

---

## 14. Checklist riêng

- [ ] Đã **hỏi và chốt stack Java + kênh giao tiếp**
- [ ] Mỗi service DB riêng, `pom.xml`/`build.gradle` riêng
- [ ] `libs/` không chứa business logic hay entity dùng chung
- [ ] Publisher/consumer/client bọc sau port, business code không import Kafka/gRPC SDK
- [ ] Consumer idempotent, có `processed_events`, đánh dấu cùng transaction
- [ ] `ack-mode: MANUAL`, commit offset sau khi xử lý xong
- [ ] Có DLQ + backoff + metric DLQ
- [ ] Outbox pattern + ShedLock cho worker chạy nhiều replica
- [ ] Mọi lời gọi đồng bộ có timeout + `@CircuitBreaker` + fallback rõ ràng
- [ ] Không gọi service khác bên trong `@Transactional`
- [ ] `requestId` truyền qua HTTP header, Kafka header, gRPC metadata
- [ ] MDC được set ở đầu mọi listener và clear trong `finally`
- [ ] Event có đủ `eventId`, `eventType`, `eventVersion`, `occurredAt`, `requestId`, `producer`
- [ ] Saga có hành động bù trừ, trạng thái lưu bền, có timeout
- [ ] `server.shutdown: graceful` được bật
