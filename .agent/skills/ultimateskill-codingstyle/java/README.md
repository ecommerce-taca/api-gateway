# Java — quy ước chung

> ⚠️ **Stack Java CHƯA ĐƯỢC CHỐT.** Cecilia yêu cầu: *"để agent hỏi từng dự án"*.
> Với dự án mới, **bắt buộc hỏi** trước khi viết dòng code đầu tiên.
> Với dự án có sẵn, đọc `pom.xml` / `build.gradle` để tự xác định, rồi xác nhận một dòng.

---

## 1. Câu hỏi bắt buộc ở đầu mỗi dự án Java mới

Bảy lựa chọn này ràng buộc lẫn nhau, nên hỏi **gộp một bảng kèm sẵn bộ khuyến nghị hoàn chỉnh**
(ngoại lệ của giới hạn 4 câu — xem `references/interview.md` nguyên tắc 2), để Cecilia duyệt cả gói
hoặc chỉ sửa vài dòng.

1. **Phiên bản Java**: 17 LTS / 21 LTS / mới hơn?
2. **Framework**: Spring Boot 3.x / Quarkus / Micronaut?
3. **Truy cập DB**: Spring Data JPA (Hibernate) / jOOQ / MyBatis / JDBC template?
4. **Migration**: Flyway / Liquibase?
5. **Blocking hay reactive (WebFlux)?** — quyết định lan ra toàn bộ codebase, không đổi giữa chừng.
6. **Build tool**: Maven / Gradle?
7. **Lombok**: dùng hay không? (nếu Java 21 có thể dùng `record` thay cho phần lớn nhu cầu)

Khuyến nghị mặc định nếu không có ràng buộc:
**Spring Boot 3.x + Java 21 + Spring Data JPA + Flyway + MapStruct + Maven + JUnit5/Mockito, blocking.**
Vẫn phải hỏi, không tự áp.

---

## 2. Đặt tên file — PascalCase, giữ hậu tố vai trò

Java bắt buộc tên file = tên class, nên PascalCase. Nhưng **hậu tố vai trò giữ nguyên**.

```
UserProfileController.java      UserProfileService.java
UserRepository.java             UserJpaRepository.java        # port / adapter
UserJpaAdapter.java             UserEntity.java
CreateUserRequest.java          UserResponse.java
UserMapper.java                 AppException.java
ErrorCode.java                  GlobalExceptionHandler.java
KafkaEventPublisher.java        UserProfileServiceTest.java
```

Package: **chữ thường, không gạch dưới**: `com.company.project.modules.user.application`.

---

## 3. Type chặt

- Generic cụ thể, **không raw type**.
- **Cấm `Map<String, Object>` làm DTO.** Dùng `record` hoặc class có field rõ.
- `Optional<T>` cho giá trị có thể vắng ở **giá trị trả về** của public method.
  Không dùng `Optional` làm tham số, không làm field.
- Không trả `null` từ public method — trả `Optional`, collection rỗng, hoặc ném exception.
- `record` cho DTO / value object / command (immutable, `equals`/`hashCode` sẵn).
- `sealed interface` + `record` cho tổng kiểu (kết quả có nhiều dạng) khi phù hợp.
- Enum thay vì hằng số `String`/`int`.

```java
// ❌
public Map<String, Object> getUser(Long id) { ... }

// ✅
public Optional<UserResponse> getUser(UserId id) { ... }

public record CreateUserCommand(
    String email,
    String rawPassword,
    UserRole role
) {}
```

---

## 4. Phân vai trò các tầng

| Tầng | Được làm | **Cấm** |
|---|---|---|
| Controller | Nhận request, gọi service, trả DTO | Business logic, gọi repository, try/catch format lỗi |
| Service | Business logic, mở transaction | Biết HTTP (`HttpServletRequest`), gọi SDK ngoài trực tiếp |
| Repository (port) | Interface truy cập dữ liệu | Business logic |
| Adapter | Implement port, biết JPA/SDK | Business logic |
| Entity | Model dữ liệu (JPA) | Bị trả thẳng ra response |
| DTO / record | Hình dạng + validate | Logic |

```java
// ✅ Controller mỏng, không try/catch
@RestController
@RequestMapping("/api/v1/users")
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserResponse create(@Valid @RequestBody CreateUserRequest request) {
        // ResponseBodyAdvice bọc envelope, GlobalExceptionHandler lo lỗi
        return userService.register(request.toCommand());
    }
}
```

---

## 5. Repository — JPA bị giấu hoàn toàn

```java
// domain/port/UserRepository.java — tầng TRONG, ngôn ngữ nghiệp vụ
public interface UserRepository {
    Optional<User> findById(UserId id);
    Optional<User> findActiveByEmail(Email email);
    boolean existsByEmail(Email email);
    User save(User user);
    Page<User> findPaged(UserQuery query);
}
```

```java
// infrastructure/persistence/UserJpaAdapter.java — tầng NGOÀI
@Repository
@RequiredArgsConstructor
public class UserJpaAdapter implements UserRepository {

    private final UserJpaRepository jpa;      // Spring Data, chỉ tồn tại ở đây
    private final UserMapper mapper;

    @Override
    public Optional<User> findActiveByEmail(Email email) {
        return jpa.findByEmailAndStatus(email.value(), UserStatus.ACTIVE)
                  .map(mapper::toDomain);
    }
}
```

- Service inject `UserRepository` (port), **không** inject `UserJpaRepository`.
- `EntityManager`, `Criteria`, `Specification`, `JPAQuery` **không được rò rỉ** khỏi adapter.
- Tên method port theo ý định nghiệp vụ: `findOverdueInvoices()`,
  không `findByDueDateBeforeAndStatusNot(...)`.
- Truy vấn phức tạp: `@Query` JPQL/native hoặc jOOQ **bên trong** adapter.

---

## 6. Transaction

- `@Transactional` đặt ở **service layer**, không ở controller, không ở repository.
- Chỉ định rõ `readOnly = true` cho thao tác đọc.
- **Không gọi API ngoài bên trong `@Transactional`.**
- Cẩn thận self-invocation: gọi method `@Transactional` từ method khác **cùng class** thì proxy
  không áp dụng — tách sang bean khác.
- Publish event sau commit: `@TransactionalEventListener(phase = AFTER_COMMIT)` hoặc outbox.

---

## 7. Exception & global handler

```java
public abstract class AppException extends RuntimeException {
    private final String errorCode;
    private final HttpStatus httpStatus;
    private final transient Map<String, Object> context;

    protected AppException(String errorCode, HttpStatus httpStatus, String message,
                           Map<String, Object> context) {
        super(message);
        this.errorCode = errorCode;
        this.httpStatus = httpStatus;
        this.context = context == null ? Map.of() : context;
    }
}

public class NotFoundException extends AppException {
    public NotFoundException(String errorCode, String message, Map<String, Object> context) {
        super(errorCode, HttpStatus.NOT_FOUND, message, context);
    }
}
```

```java
@RestControllerAdvice
@RequiredArgsConstructor
public class GlobalExceptionHandler {

    private final AppLogger logger;

    @ExceptionHandler(AppException.class)
    public ResponseEntity<ApiResponse<Object>> handleApp(AppException ex) {
        return ResponseEntity.status(ex.getHttpStatus())
            .body(ApiResponse.fail(ex.getMessage(), ex.getErrorCode(), RequestContext.requestId()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiResponse<Object>> handleValidation(MethodArgumentNotValidException ex) {
        // Gom lỗi từng field vào data.fields
        var fields = ex.getBindingResult().getFieldErrors().stream()
            .map(e -> new FieldError(e.getField(), "INVALID", e.getDefaultMessage()))
            .toList();
        return ResponseEntity.badRequest()
            .body(ApiResponse.failWithData(Map.of("fields", fields), "Dữ liệu không hợp lệ",
                                           ErrorCode.VALIDATION_FAILED, RequestContext.requestId()));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiResponse<Object>> handleUnknown(Exception ex) {
        // Lỗi 5xx: log đầy đủ ở server, client chỉ thấy thông báo chung
        logger.error("unhandled exception", ex, Map.of("requestId", RequestContext.requestId()));
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
            .body(ApiResponse.fail("Đã có lỗi xảy ra", ErrorCode.INTERNAL_ERROR,
                                   RequestContext.requestId()));
    }
}
```

- Không ném `RuntimeException` trần. Không dùng `ResponseStatusException` trong service.
- `errorCode` từ `ErrorCode.java` (enum/const), không string literal rải rác.
- Không `catch (Exception e) { }` rỗng. Không nuốt lỗi.

---

## 8. requestId qua MDC

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestContextFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res,
                                    FilterChain chain) throws ServletException, IOException {
        String requestId = Optional.ofNullable(req.getHeader("X-Request-Id"))
                                   .orElseGet(() -> UUID.randomUUID().toString());
        MDC.put("requestId", requestId);
        res.setHeader("X-Request-Id", requestId);
        try {
            chain.doFilter(req, res);
        } finally {
            MDC.clear();   // BẮT BUỘC — thread pool tái sử dụng thread, không clear là rò rỉ context
        }
    }
}
```

⚠️ **Cạm bẫy:** MDC gắn với thread. Sang `@Async`, `CompletableFuture`, hay thread pool khác
thì MDC **mất**. Phải propagate thủ công (`TaskDecorator` cho Spring `@Async`).

---

## 9. Validate

```java
public record CreateUserRequest(
    @NotBlank @Email @Size(max = 255) String email,
    @NotBlank @Size(min = 8, max = 128) String password,
    @NotNull UserRole role,
    @Size(max = 100) String displayName
) {
    public CreateUserCommand toCommand() {
        return new CreateUserCommand(email, password, role);
    }
}
```

- `@Valid` trên `@RequestBody` bắt buộc.
- Mọi `String` có `@Size(max=...)`, mọi số có `@Min`/`@Max`, mọi collection có `@Size`.
- Rule nghiệp vụ (email đã tồn tại) **không** nằm ở Bean Validation — nằm ở service.
- Entity không bao giờ nhận trực tiếp từ `@RequestBody`, không trả thẳng ra response.
- Mapping entity ↔ DTO qua **MapStruct**, không viết tay trong controller.

---

## 10. Unit test — JUnit 5 + Mockito

```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {

    @Mock private UserRepository userRepository;      // mock PORT, không mock JpaRepository
    @Mock private PasswordHasher passwordHasher;
    @InjectMocks private UserService userService;

    @Test
    void shouldRejectRegistrationWhenEmailAlreadyExists() {
        // Arrange
        given(userRepository.existsByEmail(any())).willReturn(true);

        // Act & Assert
        assertThatThrownBy(() -> userService.register(command))
            .isInstanceOf(ConflictException.class)
            .hasFieldOrPropertyWithValue("errorCode", ErrorCode.EMAIL_ALREADY_EXISTS);
    }
}
```

- **Không** `@SpringBootTest` cho unit test service — quá chậm, không cần context.
- Mock qua port. AssertJ cho assertion.
- Tên test mô tả hành vi. Arrange–Act–Assert tách bằng dòng trống.
- Không tự viết integration test (Testcontainers) trừ khi Cecilia yêu cầu.

---

## 11. Những thứ thường làm sai với Java/Spring

| Sai | Đúng |
|---|---|
| `@Autowired` trên field | Constructor injection (`@RequiredArgsConstructor` + `final`) |
| Inject `JpaRepository` vào service | Inject port, adapter mới biết JPA |
| Trả entity ra response | Map sang response DTO qua MapStruct |
| `@Transactional` trên controller | Đặt ở service |
| Gọi method `@Transactional` cùng class | Tách sang bean khác (self-invocation không qua proxy) |
| `FetchType.EAGER` mặc định | `LAZY` + fetch join tường minh khi cần |
| N+1 query | `@EntityGraph` hoặc `join fetch` |
| `@Data` của Lombok trên entity JPA | Chỉ `@Getter` + `@Setter` cần thiết (`@Data` sinh `equals/hashCode` sai với entity) |
| `ddl-auto: update` | `validate` hoặc `none` + Flyway |
| `float`/`double` cho tiền | `BigDecimal` hoặc `long` đơn vị nhỏ nhất |
| `new Date()`, `SimpleDateFormat` | `java.time` (`Instant`, `OffsetDateTime`), inject `Clock` |
| Field injection trong test | `@Mock` + `@InjectMocks` |
| `System.out.println` | Logger có cấu trúc |
| Nối chuỗi vào native query | Tham số hoá |
