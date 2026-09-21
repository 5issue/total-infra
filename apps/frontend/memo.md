### ecr로그인
```bash
aws ecr get-login-password --region "ap-northeast-2" --profile target-infra | docker login --username AWS --password-stdin 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com
```

### 새로운 빌더 생성 및 활성화
```bash
docker buildx create --name mybuilder --use
```

### 빌더 부트스트랩(초기화) 실행
```bash
docker buildx inspect --bootstrap
```

### 프론트 빌드
```bash
docker build \
  --build-arg NEXT_PUBLIC_API_URL=https://api.example.com \
  --build-arg NEXT_PUBLIC_APP_ENV=production \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest .

### 빌드 & push (멀티 아키텍처)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --no-cache \
  --build-arg NEXT_PUBLIC_API_URL=https://api.example.com \
  --build-arg NEXT_PUBLIC_APP_ENV=production \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest \
  --push .
```

### ECR에서 방금 푸시한 최신 이미지 강제 다운로드
```bash
docker pull 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest
```

### 프론트 테스트
docker run -d --name kurly-frontend -p 3000:3000 \
 -e API_INTERNAL_URL=http://api.internal \
 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest 

### 확인
docker container ls

### 제거
docker rm -f kurly-frontend

### ai 빌드 
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --provenance=false \
  -f serving/Dockerfile \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-ai-assistant:latest \
  --push .
```

### 로컬 테스트용 브리지 네트워크 생성
```bash
docker network create ai-net 2>/dev/null || true
```

### SSL 지원 PostgreSQL 실행
```bash
docker run -d --name test-postgres \
  --network ai-net \
  -e POSTGRES_USER=kurly \
  -e POSTGRES_PASSWORD=kurlypass \
  -e POSTGRES_DB=kurly_ai \
  postgres:16-alpine \
  sh -c "
    apk add --no-cache openssl && \
    mkdir -p /var/lib/postgresql/ssl && \
    openssl req -new -x509 -days 365 -nodes -text \
      -out /var/lib/postgresql/ssl/server.crt \
      -keyout /var/lib/postgresql/ssl/server.key \
      -subj '/CN=test-postgres' && \
    chmod 600 /var/lib/postgresql/ssl/server.key && \
    chown -R postgres:postgres /var/lib/postgresql/ssl && \
    docker-entrypoint.sh postgres \
      -c ssl=on \
      -c ssl_cert_file=/var/lib/postgresql/ssl/server.crt \
      -c ssl_key_file=/var/lib/postgresql/ssl/server.key
  "
```

### AI 서빙 컨테이너
```bash
docker run -d --name test-ai-serving \
  --network ai-net \
  -p 8000:8000 \
  -e ENVIRONMENT=local \
  -e DATABASE_URL="postgresql://kurly:kurlypass@test-postgres:5432/kurly_ai" \
  596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-ai-assistant:latest
```

### 확인
docker ps

