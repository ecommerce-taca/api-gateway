# NestJS — kiến trúc MICROSERVICES

> Đọc `nestjs/README.md` trước.
> **Bắt buộc hỏi Cecilia dùng kênh giao tiếp nào** — Kafka / RabbitMQ / NATS / gRPC / REST qua gateway / TCP.
> Đừng đoán, mỗi kênh kéo theo thiết kế khác nhau.

---

## 1. Cấu trúc repo

```
project/
├── docker-compose.yml              # dựng cả hệ ở local
├── libs/                           # code dùng chung — GIỮ MỎNG
│   ├── contracts/                  # event schema, proto, DTO liên service
│   ├── common/                     # envelope, AppException, error-code, request-context
│   └── observability/              # logger, tracing, metric
│
├── apps/
│   ├── api-gateway/
│   ├── user-service/
│   │   ├── src/
│   │   │   ├── main.ts
│   │   │   ├── app.module.ts
│   │   │   ├── modules/<feature>/          # cấu trúc giống monolith
│   │   │   ├── infrastructure/
│   │   │   │   ├── messaging/              # publisher + consumer adapter
│   │   │   │   ├── clients/                # gọi service khác (bọc sau port)
│   │   │   │   ├── persistence/            # DB RIÊNG của service này
│   │   │   │   └── config/
│   │   │   └── common/
│   │   ├── Dockerfile
│   │   └── package.json
│   ├── order-service/
│   └── notification-service/
```

**Cảnh báo về `libs/shared`:** đây là nơi microservices chết. Chỉ được chứa contract, tiện ích
kỹ thuật thuần và type. **Tuyệt đối không** chứa business logic hay entity dùng chung — nếu sửa
một dòng trong đó mà phải deploy lại 5 service, bạn đã có một monolith phân tán, tệ hơn monolith thật.

---

## 2. Luật bất di bất dịch

1. **Mỗi service một database riêng.** Không service nào đọc/ghi DB của service khác. Không có ngoại lệ.
2. **Không transaction phân tán.** Không 2PC. Nhất quán cuối cùng qua event + saga.
3. **Mọi consumer phải idempotent.** Message sẽ được giao lại — đó là điều chắc chắn, không phải rủi ro.
4. **Mọi lời gọi đồng bộ có timeout + circuit breaker.** Không có = một service chết kéo cả hệ chết.
5. **`requestId`/`traceId` xuyên suốt** mọi kênh, kể cả qua broker.
6. **Event chỉ thêm field.** Xoá/đổi kiểu là breaking → `eventVersion` mới, chạy song song.
7. **Ghi DB + publish event = outbox pattern.** Không publish bên trong transaction DB.

---

## 3. Chọn kênh giao tiếp

| Kênh | Dùng khi | Cảnh báo |
|---|---|---|
| **Kafka** | Event stream, cần replay, nhiều consumer group, throughput cao, giữ thứ tự theo key | Vận hành nặng. Quá mức cho hệ nhỏ |
| **RabbitMQ / NATS** | Command/event, routing linh hoạt, hệ vừa và nhỏ | Không replay được như Kafka |
| **gRPC** | Gọi đồng bộ nội bộ, cần độ trễ thấp và contract chặt | Tạo coupling thời gian — service kia chết là mình chết |
| **REST qua gateway** | Client ngoài gọi vào; gọi nội bộ đơn giản | Đừng dùng REST cho luồng cần bất đồng bộ |
| **TCP (Nest transport)** | Nội bộ, hệ nhỏ, cùng cụm mạng | Không có ecosystem tooling; cân nhắc kỹ trước khi chọn |

**Nguyên tắc chọn:** mặc định **bất đồng bộ (event)**. Chỉ dùng đồng bộ khi bên gọi **thật sự cần
kết quả ngay để trả lời client**. Mỗi lời gọi đồng bộ là một điểm gãy thêm.

---

## 4. Publisher — luôn bọc sau port

```ts
// libs/common/ports/event-publisher.port.ts — tầng TRONG
export abstract class EventPublisherPort {
  abstract publish(event: DomainEvent): Promise<void>;
  abstract publishAll(events: DomainEvent[]): Promise<void>;
}
```

```ts
// infrastructure/messaging/kafka-event.publisher.ts — tầng NGOÀI
@Injectable()
export class KafkaEventPublisher implements EventPublisherPort {
  constructor(private readonly producer: Producer, private readonly logger: AppLogger) {}

  async publish(event: DomainEvent): Promise<void> {
    const requestId = RequestContext.getRequestId();
    await this.producer.send({
      topic: event.eventType,
      messages: [{
        key: event.aggregateId,                       // cùng aggregate → cùng partition → giữ thứ tự
        value: JSON.stringify(event),
        headers: { 'x-request-id': requestId, 'x-event-id': event.eventId },
      }],
    });
  }
}
```

Business code chỉ biết `EventPublisherPort`. Đổi Kafka → RabbitMQ chỉ thay adapter + wiring.

---

## 5. Outbox pattern — bắt buộc khi ghi DB + phát event

Vấn đề: nếu commit DB xong rồi publish mà publish lỗi → event mất. Nếu publish trước rồi commit lỗi
→ event ma. Cả hai đều hỏng.

```ts
// B1 — trong transaction: ghi dữ liệu + ghi outbox cùng lúc
await this.transactionManager.run(async (ctx) => {
  const order = await this.orderRepo.save(order, ctx);
  await this.outboxRepo.enqueue(new OrderCreatedEvent(order.id), ctx);
});

// B2 — worker riêng: đọc outbox chưa gửi → publish → đánh dấu đã gửi
// Có thể gửi trùng (at-least-once) → chính vì vậy consumer PHẢI idempotent
```

Bảng outbox tối thiểu: `id, aggregateId, eventType, eventVersion, payload, requestId, createdAt, publishedAt, retryCount`.

---

## 6. Consumer — idempotent, có DLQ

```ts
@Injectable()
export class OrderCreatedConsumer {
  async handle(event: OrderCreatedEvent, meta: MessageMeta): Promise<void> {
    // Khôi phục requestId từ header để log nối được với luồng gốc
    await RequestContext.runWith({ requestId: meta.requestId }, async () => {

      // Chống xử lý lặp — bảng processed_events (eventId là khoá chính)
      if (await this.processedEvents.exists(event.eventId)) {
        this.logger.debug('event already processed, skipping', { eventId: event.eventId });
        return;
      }

      await this.transactionManager.run(async (ctx) => {
        await this.useCase.execute(event, ctx);
        await this.processedEvents.mark(event.eventId, ctx);  // đánh dấu cùng transaction
      });
    });
  }
}
```

Yêu cầu:

- Bảng `processed_events` (hoặc khoá tự nhiên trong nghiệp vụ) để chống lặp — đánh dấu **cùng transaction** với việc xử lý.
- **Dead-letter queue** cho message xử lý thất bại quá số lần. Có DLQ mà không ai xem thì vô nghĩa —
  phải có metric số message trong DLQ.
- Retry có backoff. Lỗi **không thể phục hồi** (payload sai schema) → vào DLQ ngay, đừng retry vô ích.
- Consumer chậm không được block: đo lag, cảnh báo khi lag tăng.

---

## 7. Gọi đồng bộ giữa các service

```ts
// domain/ports/user-lookup.port.ts — tầng TRONG, nói ngôn ngữ nghiệp vụ
export abstract class UserLookupPort {
  abstract getBasicInfo(userId: string): Promise<UserBasicInfo | null>;
}
```

```ts
// infrastructure/clients/user-service.client.ts — tầng NGOÀI
@Injectable()
export class UserServiceClient implements UserLookupPort {
  async getBasicInfo(userId: string): Promise<UserBasicInfo | null> {
    try {
      const res = await this.http.get(`/internal/v1/users/${userId}`, {
        timeout: 3_000,                                          // BẮT BUỘC
        headers: { 'x-request-id': RequestContext.getRequestId() }, // truyền trace
      });
      return UserMapper.fromDto(res.data.data);
    } catch (err) {
      if (isNotFound(err)) return null;
      // Dịch lỗi hạ tầng sang exception của mình, không để AxiosError trôi lên
      throw new ExternalServiceException('USER_SERVICE_UNAVAILABLE', 'user-service không phản hồi');
    }
  }
}
```

Bắt buộc:

- **Timeout** trên mọi lời gọi.
- **Circuit breaker** (opossum hoặc tương đương) cho service hay lỗi — mở mạch thay vì để request dồn.
- **Fallback** rõ ràng khi mạch mở: trả dữ liệu cache, trả một phần, hoặc lỗi 503 sạch sẽ.
- **Không gọi chuỗi sâu.** A→B→C→D là thiết kế sai; cân nhắc event hoặc gộp dữ liệu.
- Không gọi service khác **bên trong transaction DB**.

---

## 8. Saga — nhất quán cuối cùng

Khi một nghiệp vụ trải qua nhiều service, không có transaction chung. Dùng **choreography** (mỗi service
phản ứng với event) cho luồng đơn giản, **orchestration** (một saga manager điều phối) cho luồng phức tạp.

```
CreateOrder (order-service)
  └─ publish order.created
       ├─ inventory-service: reserve stock
       │    ├─ ok   → publish inventory.reserved
       │    └─ fail → publish inventory.reservation-failed
       │                  └─ order-service: cancel order (BÙ TRỪ)
       └─ payment-service: charge
            ├─ ok   → publish payment.succeeded → order.confirmed
            └─ fail → publish payment.failed
                         └─ inventory-service: release stock (BÙ TRỪ)
```

Yêu cầu:

- **Mỗi bước phải có hành động bù trừ** được định nghĩa rõ ràng.
- Trạng thái saga được lưu (bảng riêng), không giữ trong bộ nhớ.
- Có timeout cho saga treo. Không bước nào chờ vô hạn.
- Vẽ luồng ra trước khi code, và **hỏi Cecilia duyệt** — saga sai là mất tiền thật.

---

## 9. API Gateway

- Là nơi duy nhất client ngoài chạm tới. Service nội bộ không lộ ra internet.
- Trách nhiệm: routing, xác thực (verify token, gắn danh tính), rate limit, sinh `requestId`,
  gộp response nếu cần, CORS.
- **Không** chứa business logic. Gateway phình logic là dấu hiệu sai kiến trúc.
- Xác thực xong, gateway truyền danh tính xuống bằng token nội bộ đã ký —
  **không** truyền header `X-User-Id` trần (service nội bộ không được tin header thô).

---

## 10. Observability

- **Bắt buộc** có distributed tracing (OpenTelemetry). Không có tracing thì debug microservices là mò kim.
- `traceId` = `requestId` để nối log và trace.
- Mỗi service log kèm `service`, `requestId`, `traceId`, và `eventId` khi xử lý message.
- Metric tối thiểu mỗi service: request rate/latency/error theo endpoint, consumer lag, kích thước DLQ,
  tỉ lệ circuit breaker mở, độ trễ lời gọi ra ngoài.
- Health: `/health` (liveness — **không** phụ thuộc DB) và `/health/ready` (readiness — kiểm DB, broker).

---

## 11. Checklist riêng cho microservices

- [ ] Mỗi service có DB riêng, không truy cập chéo
- [ ] `libs/shared` không chứa business logic hay entity dùng chung
- [ ] Publisher/consumer/client đều bọc sau port, business code không biết Kafka/gRPC
- [ ] Consumer idempotent, có `processed_events` hoặc khoá tự nhiên
- [ ] Có DLQ + retry backoff + metric cho DLQ
- [ ] Outbox pattern cho mọi luồng ghi DB + phát event
- [ ] Mọi lời gọi đồng bộ có timeout + circuit breaker + fallback rõ ràng
- [ ] `requestId`/`traceId` truyền qua mọi kênh (HTTP header, message header, gRPC metadata)
- [ ] Event có `eventId`, `eventType`, `eventVersion`, `occurredAt`, `requestId`, `producer`
- [ ] Thay đổi event chỉ thêm field; breaking change có version mới chạy song song
- [ ] Saga có hành động bù trừ đầy đủ và trạng thái được lưu bền
- [ ] Không gọi service khác bên trong transaction DB
- [ ] Gateway không chứa business logic; service nội bộ không tin header thô từ client
