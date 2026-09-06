### 클라우드 인프라 프로비저닝 저장소 입니다.


### 📁 디렉터리 구조
```text
.
├── apps/                          # 프론트엔드 애플리케이션 소스 코드
│   └── frontend/                  # Next.js 기반 반응형 웹 프론트엔드 (SSR/CSR, App Router)
│
├── iam/                           # [Stack 1] 전역 IAM 및 보안 기반 스택
│   ├── kms.tf                     # 데이터 암호화용 AWS KMS 키 설정
│   ├── mfa.tf                     # 계정 보안 강화를 위한 IAM MFA 강제 정책
│   └── spot.tf                    # Karpenter 및 Spot 인스턴스 서비스 연계 역할 (SLR)
│
├── init/                          # [Stack 2] 공통 기반 리소스 스택
│   ├── acm.tf                     # 도메인 SSL/TLS 인증서 프로비저닝
│   ├── ecr.tf                     # 애플리케이션 컨테이너 이미지 프라이빗 저장소
│   └── s3.tf                      # 정적 자산 및 테라폼 백엔드/데이터 저장용 S3 버킷
│
├── infra/                         # [Stack 3] 메인 네트워크 및 EKS 클러스터 스택
│   ├── network.tf                 # VPC, 서브넷(Public/Private), 라우팅 테이블
│   ├── nat.tf                     # 프라이빗 서브넷 아웃바운드 인터넷 통신용 NAT Gateway
│   ├── eks.tf                     # AWS EKS 제어부 및 온디맨드 관리형 기본 노드 그룹
│   ├── karpenter.tf               # 워크로드 수요 기반 Spot 인스턴스 자동 스케일러(Karpenter)
│   ├── alb.tf                     # AWS Load Balancer Controller 설정
│   ├── cloudfront.tf              # 글로벌 정적/동적 캐싱을 위한 CDN 배포
│   ├── waf.tf                     # 웹 보안 위협 방어를 위한 WAFv2 룰셋
│   ├── route53.tf                 # 도메인 DNS 레코드 자동 연동
│   ├── secrets.tf                 # AWS Secrets Manager 연동 및 K8s 시크릿 주입
│   ├── argocd.tf                  # GitOps Argo CD 초기 구성
│   └── grafana.tf                 # 시스템 모니터링 시각화 도구 프로비저닝
│
├── modules/                       # 재사용 가능한 테라폼 커스텀 모듈
│   ├── alb/                       # ALB 및 Target Group 프로비저닝 모듈
│   ├── argocd/                    # Argo CD 설치 및 기본 설정 모듈
│   ├── ebs_csi/                   # 클러스터 영구 볼륨(PV)을 위한 EBS CSI Driver 모듈
│   └── grafana/                   # Grafana 서비스 모듈
│
├── scripts/                       # 인프라 운영 및 자동화 지원 스크립트
│   └── setup-aws-iam.sh           # AWS 로컬 CLI 프로필 및 배포 권한 초기화 스크립트
│
└── Makefile                       # 계층별 인프라 배포 및 안전 파기(Destroy) 자동화 파이프라인