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

### 빌드
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
<!-- ### 빌드 예정(변경)
docker build \
  --platform linux/arm64 \
  --build-arg NEXT_PUBLIC_API_URL=https://api.example.com \
  --build-arg NEXT_PUBLIC_APP_ENV=production \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest . -->

<!-- ### ECR 푸시
```bash
docker push 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest
``` -->

### 테스트
docker run -d --name kurly-frontend -p 3000:3000 \
 -e API_INTERNAL_URL=http://api.internal \
 336925002301.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest

### 확인
docker container ls

### 제거
docker rm -f kurly-frontend