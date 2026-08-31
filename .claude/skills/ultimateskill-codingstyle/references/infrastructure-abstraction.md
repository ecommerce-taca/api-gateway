# Bọc hạ tầng — không phụ thuộc, thay thế được

> Yêu cầu gốc của Cecilia: *"tức là bọc lại, có interface rõ ràng để không phụ thuộc và có thể thay thế"*

Đây là **ngoại lệ duy nhất** được phép thêm abstraction mà không cần hỏi. Mọi abstraction khác
phải theo Luật 3 (đủ dùng, không phô trương).

---

## 1. Quy tắc

**Business code không bao giờ import trực tiếp SDK của bên thứ ba.**

Danh sách phải bọc — không đầy đủ nhưng đủ để nhận diện:

| Nhóm | Ví dụ cụ thể |
|---|---|
| Message broker | KafkaJS, `kafka-python`, Spring Kafka, amqplib, NATS client |
| RPC | gRPC client stub, TCP client |
| HTTP ra ngoài | axios, httpx, `requests`, RestTemplate, WebClient, OkHttp |
| Cache | ioredis, redis-py, Lettuce |
| Storage | AWS SDK S3, MinIO client, GCS |
| Mail / SMS / Push | SendGrid, Twilio, FCM |
| Payment | Stripe, VNPay, MoMo, PayPal |
| ORM / DB driver | TypeORM, SQLAlchemy, JPA, mongoose, pg |
| Logger | winston, pino, logback, structlog |
| Thời gian & ngẫu nhiên | `Date.now()`, `uuid()`, `Math.random()`, `LocalDateTime.now()` |
| Config / secret | `process.env`, `os.environ`, Vault client |
| Search / Vector | Elasticsearch, OpenSearch, Qdrant |

Nếu nó nằm ngoài process của bạn, hoặc nó không deterministic → **bọc**.

---

## 2. Hình dạng chuẩn

Ba phần, luôn luôn:

```
1. PORT      — interface, ngôn ngữ nghiệp vụ, ở tầng TRONG (domain/application)
2. ADAPTER   — implementation, biết SDK, ở tầng NGOÀI (infrastructure)
3. WIRING    — DI container ghép port ↔ adapter, ở module/config
```

**Nguyên tắc đặt interface:** interface thuộc về **người dùng nó**, không thuộc về người implement nó.
Vì vậy nó nằm cạnh business code, không nằm cạnh adapter.

---

## 3. Interface phải nói ngôn ngữ nghiệp vụ

Đây là chỗ hầu hết mọi người làm sai: bọc lại nhưng interface vẫn là hình dạng của SDK.

```ts
// ❌ Bọc giả — vẫn lộ Kafka ra ngoài, đổi sang RabbitMQ là gãy hết
interface KafkaService {
  send(topic: string, key: string, value: Buffer, partition?: number): Promise<RecordMetadata>;
}

// ✅ Bọc thật — nói về nghiệp vụ, hạ tầng nào cũng thay được
interface DomainEventPublisher {
  publish(event: DomainEvent): Promise<void>;
  publishAll(events: DomainEvent[]): Promise<void>;
}
```

```ts
// ❌ Lộ hình dạng của thư viện HTTP
interface PaymentApi {
  post(path: string, body: unknown): Promise<AxiosResponse>;
}

// ✅ Nói ý định
interface PaymentGateway {
  charge(cmd: ChargeCommand): Promise<PaymentResult>;
  refund(cmd: RefundCommand): Promise<RefundResult>;
}
```

Kiểm tra nhanh: **nếu mai đổi Kafka sang RabbitMQ, interface có phải sửa không?**
Có → chưa bọc xong.

---

## 4. Adapter chịu trách nhiệm 5 việc

Mỗi adapter, không thiếu việc nào:

1. **Gọi SDK** — chỗ duy nhất trong codebase biết SDK đó tồn tại.
2. **Map dữ liệu** — chuyển model của mình ↔ model của SDK. Không để model SDK lọt ra ngoài.
3. **Dịch lỗi** — bắt lỗi của SDK, ném ra exception của mình.
   `AxiosError` / `KafkaJSError` / `SQLException` **không được phép** trôi lên service layer.
4. **Timeout + retry** — mọi lời gọi ra ngoài có timeout. Retry (nếu idempotent) với backoff, giới hạn lần.
5. **Log & metric** — log ở biên với `requestId`, đo thời gian gọi.

```ts
// infrastructure/payment/stripe-payment.gateway.ts
@Injectable()
export class StripePaymentGateway implements PaymentGateway {
  constructor(
    private readonly stripe: Stripe,          // SDK chỉ tồn tại ở đây
    private readonly logger: AppLogger,
  ) {}

  async charge(cmd: ChargeCommand): Promise<PaymentResult> {
    try {
      const res = await this.stripe.paymentIntents.create(
        { amount: cmd.amountInCents, currency: cmd.currency, customer: cmd.customerRef },
        { timeout: 10_000, idempotencyKey: cmd.idempotencyKey }, // (4) timeout + idempotent
      );
      return this.toPaymentResult(res);                          // (2) map ra model của mình
    } catch (err) {
      // (3) dịch lỗi — không để StripeError trôi lên trên
      this.logger.warn('stripe charge failed', { ref: cmd.idempotencyKey, err });
      throw ExternalServiceException.from('STRIPE', err);
    }
  }
}
```

---

## 5. Config — một cửa duy nhất

`process.env` / `os.environ` / `@Value` **chỉ được đọc ở đúng một chỗ**: module config.

- Config được **validate lúc khởi động**, fail fast nếu thiếu hoặc sai kiểu.
  (Zod / Joi cho TS, Pydantic `BaseSettings` cho Python, `@ConfigurationProperties` + `@Validated` cho Java.)
- Config được inject dưới dạng **object có type**, không phải string rời rạc.
- Secret không bao giờ có giá trị mặc định trong code. Thiếu secret → chết ngay lúc boot, không chạy tiếp.
- `.env.example` liệt kê đủ key với giá trị giả, không chứa giá trị thật.

```ts
// ❌ Rải rác khắp nơi
const url = process.env.DB_URL ?? 'postgres://localhost:5432/dev';

// ✅ Một cửa, có validate, fail fast
const AppConfigSchema = z.object({
  DB_URL: z.string().url(),
  KAFKA_BROKERS: z.string().transform(s => s.split(',')),
  JWT_SECRET: z.string().min(32),          // không default cho secret
});
export type AppConfig = z.infer<typeof AppConfigSchema>;
```

---

## 6. Logger — bọc luôn, đừng gọi thẳng

Business code gọi `AppLogger` của mình, không gọi `winston`/`logback`/`structlog` trực tiếp.

Lý do: đổi backend log, thêm `requestId` tự động, che field nhạy cảm — làm một chỗ, không sửa 200 file.

```ts
interface AppLogger {
  debug(msg: string, ctx?: LogContext): void;
  info(msg: string, ctx?: LogContext): void;
  warn(msg: string, ctx?: LogContext): void;
  error(msg: string, err: unknown, ctx?: LogContext): void;
}
```

Chi tiết nội dung log + che dữ liệu nhạy cảm: **[security-logging.md](security-logging.md)**.

---

## 7. Base class dùng chung — có, nhưng đừng phình

Cecilia thích có base class riêng của dự án thay vì dùng trần mặc định của framework.
Nhưng base class phải mỏng, và chỉ chứa thứ **thật sự dùng chung**.

Nên có:

- `BaseEntity` — `id`, `createdAt`, `updatedAt`, `deletedAt` (soft delete nếu dự án dùng).
- `BaseRepository<T, ID>` — `findById`, `save`, `delete`, phân trang. **Không** phình thành 40 method.
- `AppException` — base cho cây exception ở `core-principles.md` §8.
- `AppLogger`, `AppConfig` — như trên.
- Response envelope builder / interceptor — xem `api-contract.md`.

Không nên có:

- `BaseService` chứa logic nghiệp vụ chung chung — mỗi service khác nhau, ép chung sẽ vỡ.
- `BaseController` nhét mọi CRUD generic — làm mất kiểm soát contract API.
- `BaseUtils` / `CommonHelper` — file rác. Tách theo chủ đề: `date.util`, `money.util`.

---

## 8. Cấu trúc thư mục hạ tầng

Non-microservices (theo module):

```
src/modules/<feature>/
├── domain/ports/            # interface: repository, publisher, gateway
└── infrastructure/          # adapter tương ứng
```

Hạ tầng dùng chung toàn app:

```
src/infrastructure/
├── config/         # config module có validate
├── logging/        # AppLogger + adapter
├── persistence/    # datasource, base repository, migration
├── messaging/      # kafka / rabbitmq / nats adapter, outbox
├── http/           # http client bọc sẵn (timeout, retry, trace header)
├── cache/          # cache port + redis adapter
└── storage/        # s3/minio adapter
```

---

## 9. Checklist trước khi coi là "đã bọc xong"

- [ ] Business code không có dòng `import` nào tới SDK bên ngoài.
- [ ] Interface đặt tên theo nghiệp vụ, đổi công nghệ không phải sửa interface.
- [ ] Interface nằm ở tầng trong, adapter nằm ở tầng ngoài.
- [ ] Adapter dịch lỗi SDK sang exception của mình.
- [ ] Mọi lời gọi ra ngoài có timeout.
- [ ] Không có model của SDK lọt ra khỏi adapter.
- [ ] Unit test service mock được interface này mà không cần chạy hạ tầng thật.
- [ ] `process.env` chỉ xuất hiện trong module config.
