# Java — kiến trúc KHÔNG microservices (modular monolith)

> Đọc `java/README.md` trước — **và nhớ hỏi stack Java trước khi làm gì**.

---

## 1. Cấu trúc — Mức 1: Modular theo feature *(mặc định)*

```
src/main/java/com/company/project/
├── ProjectApplication.java
│
├── modules/
│   ├── user/
│   │   ├── UserController.java
│   │   ├── UserService.java
│   │   ├── UserRepository.java          # PORT (interface)
│   │   ├── UserJpaAdapter.java          # ADAPTER
│   │   ├── UserJpaRepository.java       # Spring Data, package-private
│   │   ├── UserMapper.java              # MapStruct
│   │   ├── UserFacade.java              # API công khai cho module khác
│   │   ├── dto/
│   │   │   ├── CreateUserRequest.java
│   │   │   └── UserResponse.java
│   │   └── entity/
│   │       └── UserEntity.java
│   └── order/ ...
│
├── common/
│   ├── exception/    AppException.java + cây con
│   ├── error/        ErrorCode.java              # catalog duy nhất
│   ├── dto/          ApiResponse.java, PagedResponse.java
│   ├── context/      RequestContext.java (MDC)
│   ├── web/          GlobalExceptionHandler.java, ResponseBodyAdvice
│   └── annotation/   @CurrentUser, @PublicEndpoint
│
└── infrastructure/
    ├── config/       AppProperties.java (@ConfigurationProperties + @Validated)
    ├── logging/      AppLogger.java + LogbackAppLogger.java
    ├── persistence/  BaseEntity.java, JpaConfig.java
    ├── cache/        CachePort.java + RedisCacheAdapter.java
    ├── http/         HttpClientPort.java + RestClientAdapter.java
    └── storage/      FileStoragePort.java + S3StorageAdapter.java

src/main/resources/db/migration/       # Flyway
src/test/java/...                      # phản chiếu cấu trúc main
```

## 2. Cấu trúc — Mức 3: Clean/Hexagonal *(nghiệp vụ phức tạp)*

Chỉ dựng sau khi đánh giá theo `references/core-principles.md` §2 **và Cecilia đồng ý**.

```
modules/order/
├── domain/
│   ├── model/       Order.java, OrderStatus.java, Money.java   # POJO thuần, KHÔNG @Entity
│   ├── service/     PricingDomainService.java
│   ├── event/       OrderCreatedEvent.java
│   └── port/        OrderRepository.java, PaymentGateway.java
├── application/
│   ├── usecase/     CreateOrderUseCase.java, CancelOrderUseCase.java
│   └── command/     CreateOrderCommand.java
├── infrastructure/
│   ├── persistence/ OrderEntity.java (@Entity), OrderJpaAdapter.java, OrderPersistenceMapper.java
│   └── gateway/     StripePaymentGateway.java
└── presentation/
    ├── OrderController.java
    └── dto/         CreateOrderRequest.java, OrderResponse.java
```

**Điểm mấu chốt:** `domain/model/Order.java` là POJO thuần — không `@Entity`, không `@Column`,
không import `jakarta.persistence`. `OrderEntity` mới là model JPA. Nối bằng mapper.
Đây là cái giá của Mức 3, và cũng là lý do không dùng nó cho CRUD.

---

## 3. Ranh giới module — nghiêm ngặt

1. Module A **không import** class internal của module B.
2. Giao tiếp qua **facade** (interface hẹp module B công khai) hoặc **Spring event nội bộ**.
3. **Không JOIN** qua bảng của module khác.
4. Dùng **package-private** làm hàng rào thật: chỉ `Facade`, `Controller` và DTO công khai là `public`;
   `Service`, `JpaRepository`, `Entity` để package-private.

```java
// modules/user/UserFacade.java — public, hẹp
public interface UserFacade {
    Optional<UserBasicInfo> getBasicInfo(UserId userId);
    boolean isActive(UserId userId);
}

// modules/user/UserService.java — package-private, module khác không chạm được
class UserService { ... }
```

```java
// ❌ Coupling chặt
public class OrderService {
    private final UserService userService;    // internal của module khác
}

// ✅ Qua facade
public class OrderService {
    private final UserFacade userFacade;
}
```

**Kiểm tra tự động:** dùng **ArchUnit** trong test để ép ranh giới — đây là cách duy nhất giữ được
kỷ luật khi codebase lớn lên.

```java
// Cấm module order phụ thuộc vào bất cứ thứ gì của module user, TRỪ Facade và DTO công khai.
// Phần loại trừ phải nằm TRONG dependOnClassesThat() — nếu đặt ở .andShould() thì điều kiện
// áp lên chính class bị kiểm tra, không phải class đích, và rule sẽ không thực thi đúng ý định.
@ArchTest
static final ArchRule orderShouldOnlyUseUserFacade =
    noClasses().that().resideInAPackage("..modules.order..")
        .should().dependOnClassesThat(
            resideInAPackage("..modules.user..")
                .and(not(simpleNameEndingWith("Facade")))
                .and(not(resideInAPackage("..modules.user.dto..")))
        );

@ArchTest
static final ArchRule domainShouldNotDependOnFramework =
    noClasses().that().resideInAPackage("..domain..")
        .should().dependOnClassesThat()
        .resideInAnyPackage("org.springframework..", "jakarta.persistence..");
```

---

## 4. Dependency Injection

- **Constructor injection**, luôn luôn. `@RequiredArgsConstructor` + field `final`.
- **Không** `@Autowired` trên field. Không setter injection.
- Không `@Component` cho class không cần Spring quản lý — domain object là POJO thường.
- Bean định nghĩa trong `@Configuration` khi cần kiểm soát khởi tạo (client HTTP, producer, `Clock`).

```java
@Configuration
public class TimeConfig {
    // Inject Clock để test được logic phụ thuộc thời gian
    @Bean
    public Clock clock() { return Clock.systemUTC(); }
}
```

---

## 5. Transaction

```java
@Service
@RequiredArgsConstructor
public class OrderService {

    @Transactional
    public Order createOrder(CreateOrderCommand cmd) {
        Order order = orderRepository.save(Order.create(cmd));
        inventoryFacade.reserve(cmd.items());
        // Event vào outbox trong transaction, phát sau khi commit
        outbox.enqueue(new OrderCreatedEvent(order.id()));
        return order;
    }

    @Transactional(readOnly = true)
    public Optional<Order> findById(OrderId id) { ... }
}
```

Bắt buộc:

- `@Transactional` chỉ ở service. `readOnly = true` cho thao tác đọc.
- Transaction ngắn. **Không gọi API ngoài bên trong.**
- Self-invocation không qua proxy — tách bean nếu cần.
- Publish event: `@TransactionalEventListener(phase = AFTER_COMMIT)` hoặc outbox.
- Ưu thế lớn nhất của monolith là ACID thật — tận dụng trước khi nghĩ tới saga.

---

## 6. Database & JPA

- **Flyway bắt buộc**, `spring.jpa.hibernate.ddl-auto: validate` (hoặc `none`). Không bao giờ `update`.
- Migration đặt tên mô tả: `V12__add_idempotency_key_to_orders.sql`.
- `BaseEntity` chứa `id`, `createdAt`, `updatedAt` qua `@MappedSuperclass` + `@EntityListeners`.
- **Không dùng `@Data` của Lombok trên entity** — nó sinh `equals`/`hashCode` dựa trên mọi field,
  gây lỗi với lazy proxy và collection. Dùng `@Getter` + `equals`/`hashCode` theo `id`.
- `FetchType.LAZY` cho mọi quan hệ. Fetch join tường minh khi cần.
- Chống N+1: `@EntityGraph` hoặc `join fetch` trong `@Query`.
- Tiền: `BigDecimal` với `@Column(precision = 19, scale = 4)`, hoặc `long` đơn vị nhỏ nhất. **Không `double`.**
- Thời gian: `Instant` / `OffsetDateTime`, cột `timestamptz`, lưu UTC.
- Schema Postgres chia theo module nếu được (`@Table(schema = "user")`).
- Index cho mọi khoá ngoại và cột lọc/sắp xếp thường xuyên.

---

## 7. Async trong monolith

- `@Async` cần `@EnableAsync` và **`TaskDecorator` để propagate MDC** — thiếu là mất `requestId` trong log.
- Việc quan trọng cần retry/theo dõi → hàng đợi thật, **nhưng phải hỏi trước khi thêm dependency**.
- `@Scheduled`: nhiều instance sẽ chạy trùng → cần khoá phân tán (ShedLock) nếu chạy nhiều replica.
- Task nhận **id**, không nhận cả object.

---

## 8. Khi nào NÊN tách microservices

Giống `nestjs/monolith.md` §7. Với Java có thêm điểm cân nhắc: Spring Boot khởi động chậm và
tốn RAM, nên tách thành nhiều service nhỏ **đắt hơn** so với Node/Python — cân nhắc kỹ,
modular monolith với ArchUnit thường là lựa chọn đúng lâu hơn bạn nghĩ.

---

## 9. Checklist riêng

- [ ] Đã **hỏi và chốt stack Java** trước khi code
- [ ] Có ArchUnit test ép ranh giới module và ranh giới tầng
- [ ] `Service`, `JpaRepository`, `Entity` để package-private; chỉ `Facade`/`Controller`/DTO là public
- [ ] Constructor injection, không `@Autowired` field
- [ ] Service inject port, không inject `JpaRepository`
- [ ] `ddl-auto: validate`, có Flyway migration đầy đủ
- [ ] Không `@Data` trên entity JPA
- [ ] `FetchType.LAZY` mặc định, không N+1
- [ ] `@Transactional` ở service, `readOnly` cho đọc, không gọi API ngoài bên trong
- [ ] Tiền dùng `BigDecimal`/`long`, thời gian dùng `java.time` + `Clock` inject
- [ ] MDC được clear trong `finally`, propagate sang `@Async`
- [ ] Unit test không dùng `@SpringBootTest`
