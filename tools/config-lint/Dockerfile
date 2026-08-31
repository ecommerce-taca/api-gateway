# Image chỉ để chạy lint cấu hình. Ghim cả python lẫn PyYAML để CI và máy dev cho ra
# cùng một kết quả; không cài gì lên máy người dùng.
FROM python:3.13.1-alpine3.21

RUN pip install --no-cache-dir PyYAML==6.0.2

WORKDIR /work
ENTRYPOINT ["python3", "/work/tools/config-lint/kong_config_linter.py"]
