# NestJS — quy ước chung

> Stack **đã chốt**: NestJS + TypeORM + PostgreSQL. Không cần hỏi lại stack.
> Vẫn phải phỏng vấn về phạm vi, nghiệp vụ, dữ liệu — xem `references/interview.md`.

Đọc file này trước, rồi đọc `monolith.md` hoặc `microservices.md` tuỳ kiến trúc.

---

## 1. Cấu hình bắt buộc

### `tsconfig.json`

```jsonc
{
  "compilerOptions": {
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "strictPropertyInitialization": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

`any` bị cấm. Không rõ kiểu → `unknown` rồi narrow.

### `main.ts` — luôn có đủ

```ts
async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });

  app.useLogger(app.get(AppLogger));
  app.setGlobalPrefix('api');
  app.enableVersioning({ type: VersioningType.URI, defaultVersion: '1' });

  // whitelist: loại field lạ; forbidNonWhitelisted: báo lỗi nếu client gửi field thừa
  app.useGlobalPipes(new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    transformOptions: { enableImplicitConversion: false },
  }));

  app.useGlobalInterceptors(new ResponseInterceptor());  // bọc envelope
  app.useGlobalFilters(new AllExceptionsFilter());       // global handler duy nhất

  app.enableShutdownHooks();   // cần cho graceful shutdown
  await app.listen(config.port);
}
```

---

## 2. Đặt tên file — kebab-case + hậu tố vai trò

```
user-profile.controller.ts     user-profile.service.ts
user-profile.repository.ts     user-profile.module.ts
user.entity.ts                 create-user.dto.ts
user-response.dto.ts           user.mapper.ts
jwt-auth.guard.ts              response.interceptor.ts
all-exceptions.filter.ts       kafka-event.publisher.ts
user-created.event.ts          user.repository.port.ts
user-profile.service.spec.ts
```

Nhìn tên là biết vai trò. Không có file `helpers.ts`, `utils.ts`, `common.ts` chứa hổ lốn.

---

## 3. Phân vai trò các tầng — không được lẫn

| Tầng | Được làm | **Cấm** |
|---|---|---|
| Controller | Nhận request, gọi service, trả `data` thuần | Business logic, truy vấn DB, try/catch format lỗi, tự bọc envelope |
| Service | Toàn bộ business logic, điều phối, mở transaction | Biết ORM, biết HTTP (`Request`/`Response`), gọi SDK ngoài |
| Repository | Truy cập dữ liệu, giấu hoàn toàn TypeORM | Business logic, tự mở transaction |
| Adapter | Gọi SDK ngoài, map dữ liệu, dịch lỗi | Business logic |
| DTO | Định nghĩa hình dạng + validate | Logic |
| Entity | Model dữ liệu | Bị trả thẳng ra response |

```ts
// ✅ Controller đúng chuẩn — mỏng, không try/catch, trả data thuần
@Controller({ path: 'users', version: '1' })
export class UserController {
  constructor(private readonly userService: UserService) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  async create(@Body() dto: CreateUserDto): Promise<UserResponseDto> {
    // ResponseInterceptor tự bọc envelope, AllExceptionsFilter tự xử lý lỗi
    return this.userService.create(dto);
  }
}
```

---

## 4. Repository — TypeORM bị giấu hoàn toàn

Service **không được** inject `Repository<T>` của TypeORM, không được thấy `DataSource`,
`EntityManager`, `QueryBuilder`.

```ts
// domain/ports/user.repository.port.ts  — tầng TRONG
export abstract class UserRepositoryPort {
  abstract findById(id: string): Promise<User | null>;
  abstract findActiveByEmail(email: string): Promise<User | null>;
  abstract existsByEmail(email: string): Promise<boolean>;
  abstract save(user: User): Promise<User>;
  abstract findPaged(query: UserQuery): Promise<Paged<User>>;
}
```

```ts
// infrastructure/persistence/user.typeorm.repository.ts  — tầng NGOÀI
@Injectable()
export class UserTypeOrmRepository implements UserRepositoryPort {
  constructor(@InjectRepository(UserEntity) private readonly repo: Repository<UserEntity>) {}

  async findActiveByEmail(email: string): Promise<User | null> {
    // QueryBuilder chỉ được phép tồn tại bên trong repository
    const row = await this.repo.findOne({ where: { email, status: UserStatus.ACTIVE } });
    return row ? UserMapper.toDomain(row) : null;
  }
}
```

```ts
// module — bind port với adapter
providers: [
  { provide: UserRepositoryPort, useClass: UserTypeOrmRepository },
]
```

Dùng `abstract class` thay vì `interface` cho port, vì DI của Nest cần token tồn tại lúc runtime.
Đây là lý do duy nhất được phép — không dùng `Symbol` + `@Inject()` rườm rà nếu không cần.

### Transaction

Transaction do **service** quyết định phạm vi, không phải repository.

```ts
// Dùng một wrapper của mình, không rắc `DataSource` khắp service
await this.transactionManager.run(async (ctx) => {
  const order = await this.orderRepo.save(newOrder, ctx);
  await this.inventoryRepo.decrease(items, ctx);
  return order;
});
```

---

## 5. Envelope + requestId

### Interceptor bọc envelope

```ts
@Injectable()
export class ResponseInterceptor<T> implements NestInterceptor<T, ApiResponse<T>> {
  intercept(ctx: ExecutionContext, next: CallHandler): Observable<ApiResponse<T>> {
    const requestId = RequestContext.getRequestId();  // AsyncLocalStorage
    return next.handle().pipe(map((data) => ({
      success: true,
      data: data ?? null,
      message: 'OK',
      errorCode: null,
      requestId,
      timestamp: new Date().toISOString(),
    })));
  }
}
```

### Filter xử lý lỗi — global handler duy nhất

```ts
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  constructor(private readonly logger: AppLogger) {}

  catch(exception: unknown, host: ArgumentsHost): void {
    const res = host.switchToHttp().getResponse<Response>();
    const requestId = RequestContext.getRequestId();
    const mapped = this.mapToApiError(exception);   // AppException | ValidationError | unknown

    // Lỗi 5xx là bất thường → log error kèm đủ ngữ cảnh để tra bằng requestId
    if (mapped.status >= 500) this.logger.error('unhandled exception', exception, { requestId });

    res.status(mapped.status).json({
      success: false,
      data: mapped.details ?? null,
      message: mapped.message,
      errorCode: mapped.errorCode,
      requestId,
      timestamp: new Date().toISOString(),
    });
  }
}
```

### requestId qua AsyncLocalStorage

```ts
// middleware chạy đầu tiên, trước mọi thứ
export class RequestContextMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction): void {
    const requestId = (req.headers['x-request-id'] as string) ?? randomUUID();
    res.setHeader('X-Request-Id', requestId);
    RequestContext.storage.run({ requestId }, () => next());
  }
}
```

Service **không** nhận `requestId` qua tham số. Logger tự lấy từ context.

---

## 6. DTO & validate

```ts
export class CreateUserDto {
  @IsEmail()
  @MaxLength(255)
  readonly email!: string;

  @IsString()
  @MinLength(8)
  @MaxLength(128)
  readonly password!: string;

  @IsEnum(UserRole)
  readonly role!: UserRole;

  @IsOptional()
  @IsString()
  @MaxLength(100)
  readonly displayName?: string;
}
```

- `readonly` + `!` cho field bắt buộc.
- Mọi chuỗi có `@MaxLength`, mọi số có `@Min`/`@Max`, mọi mảng có `@ArrayMaxSize`.
- DTO response là class riêng, chỉ chứa field được phép lộ. Không dùng `@Exclude()` trên entity
  để "nhớ giấu" — dùng DTO riêng để chặn ở mức cấu trúc.
- Mapper riêng (`user.mapper.ts`), không map trong controller.

---

## 7. Custom exception

```ts
// common/exceptions/app.exception.ts
export abstract class AppException extends Error {
  protected constructor(
    readonly errorCode: string,
    readonly httpStatus: number,
    message: string,
    readonly context?: Record<string, unknown>,
  ) { super(message); }
}

export class NotFoundException extends AppException {
  constructor(errorCode: string, message: string, context?: Record<string, unknown>) {
    super(errorCode, 404, message, context);
  }
}

export class BusinessRuleException extends AppException {
  constructor(errorCode: string, message: string, context?: Record<string, unknown>) {
    super(errorCode, 422, message, context);
  }
}
```

```ts
// dùng
if (!user) throw new NotFoundException('USER_NOT_FOUND', 'Không tìm thấy người dùng', { userId: id });
```

`errorCode` lấy từ catalog chung (`common/errors/error-code.ts`), không viết string literal rải rác.

Không dùng `HttpException` của Nest trong business code — nó buộc service phải biết về HTTP.

---

## 8. Unit test service

```ts
describe('UserService', () => {
  let service: UserService;
  let userRepo: jest.Mocked<UserRepositoryPort>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      providers: [
        UserService,
        { provide: UserRepositoryPort, useValue: createMock<UserRepositoryPort>() },
        { provide: PasswordHasherPort, useValue: createMock<PasswordHasherPort>() },
      ],
    }).compile();

    service = module.get(UserService);
    userRepo = module.get(UserRepositoryPort);
  });

  it('should reject registration when email already exists', async () => {
    // Arrange
    userRepo.existsByEmail.mockResolvedValue(true);

    // Act & Assert
    await expect(service.register(dto)).rejects.toMatchObject({ errorCode: 'EMAIL_ALREADY_EXISTS' });
  });
});
```

- Mock qua **port**, không mock `Repository<T>` của TypeORM.
- File `.spec.ts` nằm cạnh file được test.
- Không tự viết e2e trừ khi Cecilia yêu cầu.

---

## 9. Những thứ thường làm sai với NestJS

| Sai | Đúng |
|---|---|
| Inject `@InjectRepository()` vào service | Inject port, adapter mới biết TypeORM |
| Controller `try/catch` để trả lỗi | Ném exception, filter lo phần còn lại |
| Trả entity thẳng ra response | Map sang response DTO |
| `synchronize: true` ở production | Luôn dùng migration |
| Dùng `HttpException` trong service | Dùng `AppException` của dự án |
| Circular dependency giữa module → `forwardRef()` | Thiết kế lại ranh giới module; `forwardRef` là mùi lỗi |
| Logic trong `@Injectable()` provider tên `XxxHelper` | Đặt vào service/domain đúng chỗ |
| `class-transformer` `@Exclude()` trên entity để giấu field | DTO response riêng |
| Global module nhét mọi thứ | Chỉ global cho config, logger, database |
