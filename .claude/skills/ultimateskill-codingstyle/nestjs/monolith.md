# NestJS — kiến trúc KHÔNG microservices (modular monolith)

> Đọc `nestjs/README.md` trước.
> Đây là mặc định của Cecilia cho dự án mới, trừ khi có lý do rõ ràng để tách service.

---

## 1. Triết lý

Một deployable duy nhất, nhưng **bên trong chia module như thể sau này tách được**.
Ranh giới module phải chặt ngay từ đầu — vì nếu ranh giới lỏng, đến lúc cần tách microservices
sẽ không tách nổi.

---

## 2. Cấu trúc — Mức 1: Modular theo feature *(mặc định)*

Dùng cho CRUD, nghiệp vụ mỏng.

```
src/
├── main.ts
├── app.module.ts
│
├── modules/
│   ├── user/
│   │   ├── user.module.ts
│   │   ├── user.controller.ts
│   │   ├── user.service.ts
│   │   ├── user.repository.port.ts        # abstract class — port
│   │   ├── user.typeorm.repository.ts     # adapter
│   │   ├── user.mapper.ts
│   │   ├── dto/
│   │   │   ├── create-user.dto.ts
│   │   │   ├── update-user.dto.ts
│   │   │   └── user-response.dto.ts
│   │   ├── entities/
│   │   │   └── user.entity.ts
│   │   └── user.service.spec.ts
│   │
│   └── order/ ...
│
├── common/                                # dùng chung, KHÔNG chứa nghiệp vụ
│   ├── decorators/       @CurrentUser, @Public
│   ├── filters/          all-exceptions.filter.ts
│   ├── interceptors/     response.interceptor.ts, logging.interceptor.ts
│   ├── guards/           jwt-auth.guard.ts, roles.guard.ts
│   ├── pipes/
│   ├── exceptions/       app.exception.ts + cây con
│   ├── errors/           error-code.ts    # catalog errorCode duy nhất
│   ├── dto/              paged.dto.ts, api-response.dto.ts
│   └── context/          request-context.ts (AsyncLocalStorage)
│
└── infrastructure/                        # hạ tầng dùng chung toàn app
    ├── config/           config.module.ts + schema validate (zod)
    ├── logging/          app-logger.port.ts + pino.logger.ts
    ├── database/         data-source.ts, base.entity.ts, transaction-manager.ts, migrations/
    ├── cache/            cache.port.ts + redis-cache.adapter.ts
    ├── http/             http-client.port.ts + axios-http-client.adapter.ts
    └── storage/          file-storage.port.ts + s3-storage.adapter.ts
```

## 3. Cấu trúc — Mức 3: Clean/Hexagonal *(khi nghiệp vụ phức tạp)*

Chỉ dựng khi đã đánh giá theo `references/core-principles.md` §2 **và Cecilia đồng ý**.

```
src/modules/order/
├── domain/
│   ├── entities/          order.entity.ts        # thuần TS, KHÔNG decorator TypeORM
│   ├── value-objects/     money.vo.ts, order-status.vo.ts
│   ├── services/          pricing.domain-service.ts
│   ├── events/            order-created.event.ts
│   └── ports/             order.repository.port.ts, payment.gateway.port.ts
│
├── application/
│   ├── use-cases/         create-order.use-case.ts, cancel-order.use-case.ts
│   └── dto/               create-order.command.ts
│
├── infrastructure/
│   ├── persistence/       order.orm-entity.ts, order.typeorm.repository.ts, order.mapper.ts
│   └── gateways/          stripe-payment.gateway.ts
│
├── presentation/
│   ├── order.controller.ts
│   └── dto/               create-order.dto.ts, order-response.dto.ts
│
└── order.module.ts
```

**Điểm mấu chốt:** `domain/entities/order.entity.ts` là class TS thuần, không `@Entity()`.
Model của TypeORM là `infrastructure/persistence/order.orm-entity.ts` — hai thứ khác nhau,
nối bằng mapper. Đây là cái giá của Mức 3, và cũng là lý do không dùng nó cho CRUD.

---

## 4. Ranh giới giữa các module — nghiêm ngặt

Đây là điều quyết định monolith này có bảo trì được không.

### Quy tắc

1. **Module A không được import service/repository/entity của module B trực tiếp.**
2. Giao tiếp giữa module qua đúng hai cách:
   - **Public facade**: module B export một service interface hẹp, chỉ chứa thứ B muốn cho người khác dùng.
   - **Domain event nội bộ**: qua `EventEmitter2`, dùng khi A không cần biết B tồn tại.
3. **Không JOIN thẳng qua bảng của module khác.** Cần dữ liệu → gọi facade.
4. Mỗi module chỉ export những gì thật sự cần trong `exports: []`. Mặc định không export gì.

```ts
// ❌ Coupling chặt — sau này không tách được
@Injectable()
export class OrderService {
  constructor(private readonly userService: UserService) {}   // import thẳng service của module khác
}

// ✅ Qua facade hẹp do module user định nghĩa
// modules/user/user.facade.port.ts
export abstract class UserFacadePort {
  abstract getBasicInfo(userId: string): Promise<UserBasicInfo | null>;
  abstract isActive(userId: string): Promise<boolean>;
}
// order chỉ biết facade, không biết UserService
```

```ts
// ✅ Hoặc event nội bộ khi không cần kết quả trả về
this.eventEmitter.emit('order.created', new OrderCreatedEvent(order.id, order.customerId));
```

**Lợi ích cụ thể:** khi cần tách `order` ra microservice, chỉ cần thay implementation của
`UserFacadePort` từ gọi in-process sang gọi HTTP/gRPC. Không phải sửa business code.

---

## 5. Transaction trong monolith

Ưu thế lớn nhất của monolith: **transaction ACID thật**, không cần saga.
Tận dụng triệt để trước khi nghĩ tới microservices.

```ts
async createOrder(cmd: CreateOrderCommand): Promise<Order> {
  return this.transactionManager.run(async (ctx) => {
    const order = await this.orderRepo.save(Order.create(cmd), ctx);
    await this.inventoryRepo.reserve(cmd.items, ctx);
    await this.outbox.enqueue(new OrderCreatedEvent(order.id), ctx);  // publish sau commit
    return order;
  });
}
```

- Phạm vi transaction do **service/use-case** quyết định.
- Transaction **càng ngắn càng tốt** — không gọi API ngoài bên trong transaction.
- Gửi event/mail/webhook: đưa vào outbox trong transaction, phát sau khi commit.
  (Ngay cả monolith cũng nên làm vậy — nếu commit fail mà mail đã gửi thì không rút lại được.)

---

## 6. Database

- Một database, **schema chia theo module** nếu Postgres cho phép (`user.users`, `order.orders`) —
  giúp ranh giới rõ và sau này tách dễ.
- Migration **luôn có**, `synchronize: false` ở mọi môi trường kể cả dev.
- Đặt tên migration mô tả: `1725000000000-AddIdempotencyKeyToOrders.ts`.
- Mỗi migration có `down()` chạy được thật.
- Index: mọi khoá ngoại, mọi cột dùng để lọc/sắp xếp thường xuyên.
- Soft delete (`deletedAt`) nếu dữ liệu cần khôi phục — nhớ index và nhớ lọc trong repository.

---

## 7. Khi nào NÊN tách sang microservices

Đừng tách vì "nghe hiện đại". Chỉ tách khi thấy dấu hiệu thật:

- Một phần hệ thống cần scale độc lập rõ rệt (vd: xử lý ảnh chiếm 90% CPU).
- Nhiều team làm song song và đang giẫm chân nhau trên cùng codebase.
- Một phần cần công nghệ hoàn toàn khác (ML bằng Python trong hệ Node).
- Yêu cầu độ sẵn sàng khác nhau rõ rệt giữa các phần.
- Chu kỳ release khác nhau bắt buộc.

**Chưa có dấu hiệu → giữ modular monolith.** Nếu ranh giới module đã chặt như §4, việc tách sau này
là chuyện của vài ngày, không phải viết lại.

---

## 8. Checklist riêng cho monolith

- [ ] Không module nào import trực tiếp internal của module khác
- [ ] Mỗi module `exports` tối thiểu, mặc định không export gì
- [ ] Không JOIN qua bảng của module khác
- [ ] `synchronize: false`, có migration đầy đủ với `down()` chạy được
- [ ] Transaction ngắn, không gọi API ngoài bên trong
- [ ] Event ra ngoài đi qua outbox, phát sau commit
- [ ] `common/` không chứa nghiệp vụ của bất kỳ module nào
- [ ] Không `forwardRef()` — nếu cần là ranh giới đang sai
