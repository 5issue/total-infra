### ecr로그인
```bash
aws ecr get-login-password --region "ap-northeast-2" --profile target-infra | docker login --username AWS --password-stdin 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com
```

### 빌드
```bash
docker build \
  --build-arg NEXT_PUBLIC_API_URL=https://api.example.com \
  --build-arg NEXT_PUBLIC_APP_ENV=production \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest .

```
<!-- ### 빌드 예정(변경)
docker build \
  --platform linux/arm64 \
  --build-arg NEXT_PUBLIC_API_URL=https://api.example.com \
  --build-arg NEXT_PUBLIC_APP_ENV=production \
  -t 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest . -->

### ECR 푸시
```bash
docker push 596601390909.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest
```

### 테스트
docker run -d --name kurly-frontend -p 3000:3000 \
 -e API_INTERNAL_URL=http://api.internal \
 336925002301.dkr.ecr.ap-northeast-2.amazonaws.com/kurly-frontend:latest

### 확인
docker container ls

### 제거
docker rm -f kurly-frontend