# Nguyên tắc cốt lõi — áp dụng cho mọi ngôn ngữ

---

## 1. Ngôn ngữ trong code

- **Định danh: tiếng Anh.** Biến, hàm, class, file, thư mục, tên bảng, tên cột, tên endpoint, tên event.
- **Comment: tiếng Việt.** Team đọc nhanh hơn.
- **Log message: tiếng Anh.** Log là để máy grep và để đọc trên hệ thống monitoring.
- **Message trả về người dùng cuối:** theo yêu cầu dự án; mặc định tách ra file/enum riêng, không hardcode giữa logic.
- **Commit message: tiếng Anh**, theo Conventional Commits (xem `git-docker-ci.md`).

### Comment viết thế nào

Comment chỉ trả lời câu hỏi **TẠI SAO**, không bao giờ trả lời **CÁI GÌ**.

```ts
// ❌ Rác — code đã nói rồi
// Lấy user theo id
const user = await this.userRepo.findById(id);

// ❌ Rác — docstring lên lớp, không ai đọc
/**
 * Hàm này lấy user.
 * @param id - id của user
 * @returns user
 */

// ✅ Tốt — giải thích quyết định mà code không nói được
// Dùng lock bi quan vì luồng thanh toán có thể chạy song song từ 2 device,
// optimistic lock ở đây gây retry storm khi khuyến mãi flash sale.
const user = await this.userRepo.findByIdForUpdate(id);

// ✅ Tốt — cảnh báo cái bẫy
// API đối tác trả 200 kèm body lỗi, không trả 4xx. Phải check field `status` thủ công.
if (res.data.status !== 'OK') { ... }
```

Quy tắc thực dụng: **nếu xoá comment đi mà không ai mất thông tin gì → xoá.**

---

## 2. Kiến trúc: chọn mức độ, đừng chọn một lần cho tất cả

Cecilia không theo một khuôn cứng. Nguyên tắc là: **modular trước, nâng cấp khi nghiệp vụ đòi.**
Agent phải **tự đánh giá quy mô rồi hỏi lại**, không tự động dựng full DDD cho một CRUD.

### Mức 1 — Modular theo feature *(mặc định)*

Dùng khi: CRUD, nghiệp vụ mỏng, ít rule, ít trạng thái.

```
src/modules/<feature>/
├── <feature>.controller.*      # nhận request, không chứa logic
├── <feature>.service.*         # toàn bộ business logic
├── <feature>.repository.*      # truy cập dữ liệu, ẩn hoàn toàn ORM
├── dto/                        # input/output, có validate
├── entities/                   # model dữ liệu
└── <feature>.module.*          # wiring
```

### Mức 2 — Modular + tách domain *(khi rule bắt đầu nhiều)*

Thêm `domain/` chứa entity nghiệp vụ, value object, và các rule thuần không phụ thuộc framework.
Service vẫn điều phối, nhưng rule nằm trong domain.

### Mức 3 — Clean / Hexagonal đầy đủ *(khi nghiệp vụ thật sự phức tạp)*

```
src/modules/<feature>/
├── domain/            # entity, value object, domain service, PORT (interface repo)
├── application/       # use case, orchestration, transaction boundary
├── infrastructure/    # ADAPTER: repo impl, kafka, http client, cache
└── presentation/      # controller, dto, mapper
```

Quy tắc phụ thuộc: **`presentation → application → domain`**, và `infrastructure → domain` (implement port).
`domain` **không import gì** từ ba tầng còn lại, không import framework, không import ORM.

### Cách chọn — dấu hiệu nâng mức

Nâng lên mức 2/3 khi thấy **từ 2 dấu hiệu trở lên**:

- Có state machine / vòng đời trạng thái (order: draft → confirmed → shipped → done/cancelled)
- Có rule nghiệp vụ cần test độc lập khỏi DB
- Có nhiều nguồn dữ liệu cho cùng một khái niệm
- Có invariant phải luôn đúng trên một cụm object (aggregate)
- Nghiệp vụ được mô tả bằng ngôn ngữ riêng của domain, không phải ngôn ngữ CRUD

**Luôn nêu đánh giá này ra và hỏi** trước khi dựng:
> *"Nghiệp vụ này có state machine + 4 rule về hạn mức → tôi đề xuất mức 2 (tách domain), chưa cần
> full hexagonal. Cecilia chốt giúp."*

---

## 3. Quy ước đặt tên

### File & thư mục — **kebab-case + hậu tố vai trò**

Nhìn tên file là biết ngay nó làm gì.

| Ngôn ngữ | Ví dụ |
|---|---|
| NestJS / TS | `user-profile.service.ts`, `user-profile.controller.ts`, `create-user.dto.ts`, `user.entity.ts`, `user.repository.ts`, `jwt-auth.guard.ts`, `kafka.publisher.ts` |
| Python | `user_profile_service.py`, `user_profile_repository.py`, `create_user_dto.py`, `user_entity.py` *(PEP8 dùng `_`, nhưng vẫn giữ hậu tố vai trò)* |
| Java | `UserProfileService.java`, `UserProfileRepository.java`, `CreateUserRequest.java`, `UserEntity.java` *(PascalCase theo chuẩn, hậu tố vai trò giữ nguyên)* |

Thư mục: luôn kebab-case, số nhiều cho tập hợp (`modules/`, `entities/`, `dto/`, `interfaces/`).

### Định danh trong code

| Loại | Quy ước | Ví dụ |
|---|---|---|
| Class / Type | `PascalCase` | `UserProfileService`, `OrderStatus` |
| Hàm / biến (TS, Java) | `camelCase` | `findActiveUsers`, `totalAmount` |
| Hàm / biến (Python) | `snake_case` | `find_active_users`, `total_amount` |
| Hằng số | `UPPER_SNAKE_CASE` | `MAX_RETRY_ATTEMPTS` |
| Boolean | tiền tố `is/has/can/should` | `isActive`, `hasPermission`, `canRefund` |
| Hàm async trả Promise | động từ thường, không cần hậu tố `Async` | `fetchOrder()` |
| Interface (TS) | **không** tiền tố `I` | `UserRepository`, không `IUserRepository` |
| Interface port (Java) | tên thuần | `UserRepository`, impl là `UserRepositoryJpaAdapter` |
| Bảng DB | `snake_case` số nhiều | `user_profiles`, `order_items` |
| Cột DB | `snake_case` | `created_at`, `total_amount` |
| Event / topic | `<domain>.<entity>.<action>` | `billing.invoice.created` |
| errorCode | `UPPER_SNAKE_CASE` có ngữ cảnh | `USER_NOT_FOUND`, `ORDER_ALREADY_PAID` |

**Cấm tên vô nghĩa:** `data`, `data2`, `temp`, `res2`, `obj`, `handle`, `process`, `doStuff`,
`utils.ts` chứa 40 hàm không liên quan.

---

## 4. Cách viết hàm

### Hàm ngắn, một việc

Trần mềm **~30 dòng**. Vượt là dấu hiệu hàm đang làm nhiều việc → tách private method có tên nói rõ ý.

```ts
// ❌ Một hàm 90 dòng làm 5 việc
async createOrder(dto) { /* validate + tính giá + trừ kho + lưu + gửi mail */ }

// ✅ Điều phối rõ ràng, chi tiết nằm trong hàm con
async createOrder(dto: CreateOrderDto): Promise<Order> {
  const customer = await this.requireActiveCustomer(dto.customerId);
  const items    = await this.resolveItems(dto.items);
  const pricing  = this.pricingService.calculate(items, customer.tier);

  const order = await this.orderRepo.save(Order.create(customer, items, pricing));
  await this.eventPublisher.publish(new OrderCreatedEvent(order.id));
  return order;
}
```

### Early return — không lồng if/else

Guard clause dồn hết lên đầu hàm. Đường đi chính (happy path) nằm ở mức thụt lề thấp nhất.

```ts
// ❌ Kim tự tháp
function process(o) {
  if (o) {
    if (o.isValid) {
      if (o.items.length > 0) {
        return doWork(o);
      } else { throw new Error('empty'); }
    } else { throw new Error('invalid'); }
  } else { throw new Error('null'); }
}

// ✅ Guard clause
function process(o: Order): Result {
  if (!o) throw new OrderNotFoundException();
  if (!o.isValid) throw new InvalidOrderException(o.id);
  if (o.items.length === 0) throw new EmptyOrderException(o.id);

  return doWork(o);
}
```

Giới hạn cứng: **không lồng quá 2 tầng** khối điều kiện/vòng lặp trong một hàm.

### Tham số

- Quá 3 tham số → gom thành một object/DTO có tên.
- Không dùng boolean flag làm tham số điều khiển nhánh (`send(user, true)` → tách thành 2 hàm).
- Không mutate tham số đầu vào.

---

## 5. Type chặt — không `any`

Đây là điều Cecilia không nhân nhượng.

| Ngôn ngữ | Bắt buộc |
|---|---|
| TypeScript | `strict: true`, `noImplicitAny`, `strictNullChecks`. **Cấm `any`**. Không rõ kiểu → `unknown` + narrow. Không `as` để ép cho qua compiler. |
| Python | Type hint đầy đủ cho mọi tham số và return. Pydantic model cho dữ liệu vào/ra. Không `Dict[str, Any]` cho payload có cấu trúc. Chạy `mypy`/`pyright` là mặc định. |
| Java | Generic cụ thể, không raw type. **Cấm `Map<String, Object>`** làm DTO. `Optional<T>` cho giá trị có thể vắng, không trả `null` từ public method. |

Dữ liệu từ ngoài (HTTP body, message queue, config, response đối tác) **phải đi qua một lớp validate**
trước khi biến thành type nội bộ. Không tin dữ liệu ngoài chỉ vì đã khai báo type.

---

## 6. SOLID — dùng như công cụ, không như tôn giáo

Cecilia theo SOLID, nhưng SOLID **không được dùng để biện minh cho over-engineering**.

| Nguyên tắc | Áp dụng thực tế |
|---|---|
| **S** — Single Responsibility | Một class một lý do để thay đổi. Service phình ra 800 dòng → tách theo use case, không tách theo "cho đẹp". |
| **O** — Open/Closed | Thêm hành vi bằng cách thêm implementation mới, không sửa `switch` khổng lồ. **Chỉ áp dụng khi đã thấy biến thể thứ 2.** |
| **L** — Liskov | Implementation không được ném exception lạ hay siết điều kiện so với interface. |
| **I** — Interface Segregation | Interface nhỏ, đúng nhu cầu của bên gọi. Không tạo `IEverythingService` 20 method. |
| **D** — Dependency Inversion | **Quan trọng nhất.** Tầng trong định nghĩa interface, tầng ngoài implement. Đây chính là gốc của Luật 4 (bọc hạ tầng). |

**Ranh giới với over-engineering** — chỉ tạo abstraction khi:

1. Nó bọc dependency bên ngoài (luôn được phép), **hoặc**
2. Đã tồn tại ≥ 2 implementation thật, **hoặc**
3. Cecilia yêu cầu.

Ngoài đó: viết class cụ thể. Cần abstraction sau thì rút ra sau — rút ra dễ hơn nhiều so với gỡ bỏ.

---

## 7. Repository pattern — DB bị giấu hoàn toàn

Business code **không được biết** đang dùng Postgres hay Mongo, TypeORM hay JPA hay SQLAlchemy.

```ts
// ❌ Service biết quá nhiều
const users = await this.dataSource
  .createQueryBuilder(User, 'u')
  .leftJoinAndSelect('u.orders', 'o')
  .where('u.status = :s', { s: 'ACTIVE' })
  .getMany();

// ✅ Service chỉ nói ý định
const users = await this.userRepository.findActiveWithOrders();
```

Quy tắc:

- **Interface repository nằm ở tầng trong** (domain/application). Implementation nằm ở infrastructure.
- Repository trả về **domain model / entity của mình**, không trả object thô của ORM lên tầng trên.
- **Không rò rỉ** `QueryBuilder`, `Session`, `EntityManager`, `Criteria`, `Q object` ra ngoài repository.
- Method repository đặt tên theo **ý định nghiệp vụ**, không theo SQL:
  `findOverdueInvoices()` chứ không `findByDueDateLessThanAndStatusNot()`.
- Truy vấn phức tạp thì viết SQL/JPQL tay **bên trong** repository — chuyện đó là việc nội bộ của nó.
- Transaction là quyết định của tầng application, không phải của repository. Repository nhận vào
  transaction context nếu cần, không tự mở transaction.

---

## 8. Xử lý lỗi

- **Custom exception theo domain.** Không ném `Error`/`Exception`/`RuntimeException` trần.
- Mỗi exception mang: `errorCode` (UPPER_SNAKE_CASE), HTTP status tương ứng, message cho người dùng,
  và context để log (id, tham số liên quan).
- **Một global handler duy nhất** dịch exception → envelope response. Controller **không** try/catch
  để định dạng lỗi.
- Chỉ `try/catch` ở nơi bạn **thật sự xử lý được** lỗi (fallback, retry, bổ sung ngữ cảnh rồi ném lại).
- **Cấm nuốt lỗi**: `catch {}` rỗng, hoặc `catch { return null }` mà không log.
- Lỗi từ hệ thống ngoài phải được **dịch sang exception của mình** ngay tại adapter — không để
  `AxiosError` / `KafkaJSError` / `SQLException` trôi lên service layer.

Cây exception khuyến nghị:

```
AppException (base: errorCode, httpStatus, message, context)
├── ValidationException          400
├── UnauthorizedException        401
├── ForbiddenException           403
├── NotFoundException            404
├── ConflictException            409   (trùng dữ liệu, vi phạm trạng thái)
├── BusinessRuleException        422   (vi phạm rule nghiệp vụ)
└── ExternalServiceException     502/503 (đối tác lỗi, timeout)
```

Chi tiết envelope + `requestId`: xem **[api-contract.md](api-contract.md)**.

---

## 9. Test — unit test cho service layer

Mặc định của Cecilia: **viết unit test cho business logic, mock repository và external.**
Không tự sinh e2e/integration nếu không được yêu cầu.

- Đối tượng test: **service / use case layer**. Đó là nơi có logic đáng test.
- Mock: repository, message publisher, HTTP client, clock, random, id generator.
  *(Chính vì mọi thứ đã bọc sau interface — Luật 4 — nên mock rất dễ. Đó là một phần lý do bọc.)*
- Không test getter/setter, không test mapping thuần, không test framework.
- Tên test mô tả hành vi: `should reject refund when order already settled`.
- Cấu trúc **Arrange – Act – Assert**, cách nhau bằng dòng trống.
- Mỗi test một assertion nghiệp vụ. Test lỗi và test happy path tách riêng.
- Bắt buộc phủ: happy path + mọi nhánh ném exception + biên (rỗng, null, 0, âm, quá hạn).
- **Không mock cái mình đang test.** Không assert vào chi tiết implementation (số lần gọi hàm private).

---

## 10. Bất biến & tác dụng phụ

- Ưu tiên `const` / `final` / immutable. Chỉ dùng biến thay đổi được khi thật sự cần.
- Hàm tính toán nên là hàm thuần. Tác dụng phụ (ghi DB, gửi event, gọi API) tập trung ở tầng
  điều phối, không rải trong hàm tính toán.
- Không dùng global mutable state.
- `Date.now()`, `Math.random()`, `uuid()` là dependency — **inject vào**, đừng gọi thẳng trong logic
  nghiệp vụ (nếu không test sẽ không deterministic).

---

## 11. Bất đồng bộ

- Nhất quán một phong cách: TS thì `async/await` (không trộn `.then()`); Python thì async xuyên suốt
  một luồng, không trộn sync-blocking vào event loop; Java thì chọn rõ blocking hay reactive, không nửa nọ nửa kia.
- Chạy song song được thì chạy song song: `Promise.all` / `asyncio.gather` / `CompletableFuture.allOf`.
  Vòng lặp `await` tuần tự trên danh sách độc lập là bug hiệu năng.
- Mọi lời gọi ra ngoài **phải có timeout**. Không có timeout = treo hệ thống.
- Retry chỉ áp cho thao tác idempotent, có backoff + số lần tối đa.
