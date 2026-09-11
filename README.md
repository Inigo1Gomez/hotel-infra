# hotel-infra

Docker y guía de despliegue en **AWS Academy (Learner Lab)** para el backend del hotel.

El `Dockerfile` vive aquí y construye cada microservicio usando su repositorio como contexto, así que
`hotel-ms-usuarios` y `hotel-ms-reservas` no necesitan cambios. Cuando se pueda tocar esos repos, se puede mover
`node-ms.Dockerfile` a cada uno.

```
                    GitHub Pages (HTTPS)
             https://inigo1gomez.github.io/hotel-frontend-admin/
                              │  Authorization: Bearer <token de Entra ID>
                              ▼
            API Gateway HTTP API (HTTPS, CORS, JWT authorizer)
            /usuarios/{proxy+}            /reservas/{proxy+}
                    │                             │
                    ▼                             ▼
   ┌──────────── EC2 Ubuntu + Docker (IP elástica) ────────────┐
   │  ms-usuarios :8082 ──► mysql (solo red interna)           │
   │  ms-reservas :8081                                        │
   └───────────────────────────────────────────────────────────┘
```

**Por qué así:** Entra ID solo acepta redirect URIs `https`, y una página `https` no puede llamar a un backend
`http` (el navegador bloquea el contenido mixto). GitHub Pages y API Gateway ya dan HTTPS sin configurar certificados.
Además los microservicios no tienen CORS: lo resuelve API Gateway.

## Probar en local (opcional, con Docker Desktop)

Con los tres repos uno al lado del otro (`hotel-infra`, `hotel-ms-usuarios`, `hotel-ms-reservas`):

```bash
cd hotel-infra
cp .env.example .env        # rellena los valores
docker compose up -d --build
curl http://localhost:8082/health
curl http://localhost:8081/health
```

## Paso a paso en AWS Academy

### 0. Iniciar el laboratorio

1. AWS Academy → tu curso → **Modules → Learner Lab** → **Start Lab**. Espera a que el punto se ponga verde y haz
   clic en **AWS** para abrir la consola. Trabaja en **N. Virginia (us-east-1)**.
2. **AWS Details → Download PEM** para bajar `labsuser.pem`, la llave del par `vockey`.

La sesión dura 4 horas. Al terminar, AWS **detiene** (no borra) las instancias; más abajo está qué hacer al volver.

### 1. Crear la EC2

**EC2 → Launch instance**:

| Campo | Valor |
| --- | --- |
| Name | `hotel-backend` |
| AMI | **Ubuntu Server 24.04 LTS** (x86_64) |
| Instance type | `t3.small` (2 GB). Con `t2.micro` (1 GB) MySQL + 2 servicios + el build quedan justos. |
| Key pair | `vockey` |
| Storage | 20 GiB gp3 |

En **Network settings → Edit**, crea el security group `hotel-backend-sg` con estas reglas de entrada:

| Tipo | Puerto | Origen | Para qué |
| --- | --- | --- | --- |
| SSH | 22 | My IP | conectarte |
| Custom TCP | 8082 | 0.0.0.0/0 | API Gateway → hotel-ms-usuarios |
| Custom TCP | 8081 | 0.0.0.0/0 | API Gateway → hotel-ms-reservas |

API Gateway llega desde IPs públicas de AWS, por eso 8081/8082 quedan abiertos; igual ambos servicios exigen un JWT
válido. **No abras el 3306**: MySQL solo se usa dentro de Docker.

### 2. Asignar una IP elástica

**EC2 → Elastic IPs → Allocate Elastic IP address → Allocate**, luego **Actions → Associate** → instancia
`hotel-backend`. Anota esa IP (`<IP_ELASTICA>`): sin ella la IP pública cambia cada vez que se reinicia el lab y habría
que reconfigurar API Gateway. Cuesta unos USD 0,005 por hora del crédito del lab.

### 3. Conectarse

Lo más simple: **EC2 → hotel-backend → Connect → EC2 Instance Connect → Connect** (terminal en el navegador).

Desde PowerShell en tu PC:

```powershell
ssh -i $HOME\Downloads\labsuser.pem ubuntu@<IP_ELASTICA>
# Si reclama "UNPROTECTED PRIVATE KEY FILE":
icacls $HOME\Downloads\labsuser.pem /inheritance:r /grant:r "$($env:USERNAME):R"
```

### 4. Instalar Docker (en la EC2)

```bash
curl -fsSL https://get.docker.com | sudo sh     # instala Docker, Compose y Buildx
sudo usermod -aG docker ubuntu
exit                                             # vuelve a conectarte para que tome el grupo docker
```

Al reconectarte, `docker compose version` debe responder. El servicio de Docker queda activo al arrancar la máquina.

### 5. Traer el código

```bash
mkdir -p ~/hotel && cd ~/hotel
git clone https://github.com/vPape8/hotel-ms-usuarios.git
git clone https://github.com/vPape8/hotel-ms-reservas.git   # su rama principal es develop
```

Para `hotel-infra`, lo más cómodo es subir esta carpeta a GitHub como repo propio y clonarla igual. Si no, cópiala
desde tu PC:

```powershell
scp -i $HOME\Downloads\labsuser.pem -r C:\Users\Iñigo\todos\hotel-infra ubuntu@<IP_ELASTICA>:~/hotel/
```

Debe quedar `~/hotel/hotel-infra`, `~/hotel/hotel-ms-usuarios` y `~/hotel/hotel-ms-reservas`. Si los repos son
privados, `git clone` pide usuario y un *personal access token* de GitHub como clave.

### 6. Configurar y levantar

```bash
cd ~/hotel/hotel-infra
cp .env.example .env
nano .env          # ENTRA_TENANT_ID y ENTRA_API_CLIENT_ID (de hotel-bff-admin) + claves de MySQL
docker compose up -d --build
docker compose ps  # tras ~1 minuto los tres deben estar "healthy"
curl http://localhost:8082/health
curl http://localhost:8081/health
```

Desde tu PC, `http://<IP_ELASTICA>:8082/health` debe responder `{"status":"ok"}`.

### 7. API Gateway (HTTPS delante de la EC2)

**API Gateway → Create API → HTTP API → Build**:

1. **Integrations → Add integration → HTTP**, método `ANY`, URL `http://<IP_ELASTICA>:8082/{proxy}`.
   Agrega otra: `ANY`, `http://<IP_ELASTICA>:8081/{proxy}`. API name: `hotel-api` → **Next**.
2. **Configure routes**:

   | Method | Resource path | Integration target |
   | --- | --- | --- |
   | `ANY` | `/usuarios/{proxy+}` | `http://<IP_ELASTICA>:8082/{proxy}` |
   | `ANY` | `/reservas/{proxy+}` | `http://<IP_ELASTICA>:8081/{proxy}` |

3. **Stages**: deja `$default` con *Auto-deploy* → **Next → Create**.
4. **Develop → CORS → Configure**:
   - Access-Control-Allow-Origin: `https://inigo1gomez.github.io` y `http://localhost:4200` (sin `/` al final)
   - Access-Control-Allow-Headers: `authorization`, `content-type`
   - Access-Control-Allow-Methods: `GET`, `POST`, `PATCH`, `DELETE`, `OPTIONS`
   - Access-Control-Max-Age: `300` → **Save**
5. **Develop → Authorization → Manage authorizers → Create**:
   - Type **JWT**, nombre `entra-id`, Identity source `$request.header.Authorization`
   - Issuer URL: `https://login.microsoftonline.com/<ENTRA_TENANT_ID>/v2.0`
   - Audience: `<ENTRA_API_CLIENT_ID>`
   - **Create**, y en la pestaña **Attach authorizers to routes** asígnalo a las dos rutas `ANY`.

   Así el API Gateway descarta tokens inválidos antes de que lleguen a la EC2, y los microservicios los vuelven a
   validar (firma, issuer, audience y expiración).
6. Copia la **Invoke URL** (`https://<api-id>.execute-api.us-east-1.amazonaws.com`) y prueba:

   ```bash
   curl https://<api-id>.execute-api.us-east-1.amazonaws.com/usuarios/health
   ```

   Con el authorizer, un `401 {"message":"Unauthorized"}` sin token es la respuesta **correcta**.

### 8. Conectar el frontend

En `hotel-frontend-admin/src/environments/environment.ts`:

```ts
api: {
  usuarios: 'https://<api-id>.execute-api.us-east-1.amazonaws.com/usuarios',
  reservas: 'https://<api-id>.execute-api.us-east-1.amazonaws.com/reservas',
},
```

Haz push a `main` y GitHub Actions lo publica en `https://inigo1gomez.github.io/hotel-frontend-admin/`
(detalle en el README del frontend).

## Cada vez que vuelves al lab

1. **Start Lab** → espera el punto verde → **AWS**.
2. **EC2 → Instances → hotel-backend**: si está `Stopped`, **Instance state → Start**.
3. Nada más: Docker arranca con la máquina, los contenedores tienen `restart: unless-stopped` y la IP elástica
   mantiene válida la integración del API Gateway.
4. Comprueba `http://<IP_ELASTICA>:8082/health`.

GitHub Pages queda siempre arriba, pero mientras el lab esté detenido las llamadas al backend fallan con 503. Antes de
presentar, inicia el lab unos 5 minutos antes.

## Tareas comunes

```bash
# Actualizar el backend con lo último de GitHub
cd ~/hotel/hotel-ms-usuarios && git pull
cd ~/hotel/hotel-ms-reservas && git pull
cd ~/hotel/hotel-infra && docker compose up -d --build

docker compose logs -f ms-usuarios                  # ver logs
docker compose exec mysql mysql -uhotel -p hotel    # entrar a MySQL
docker compose down -v                              # borrar todo, incluida la base de datos
```

## Alternativas

### Frontend en S3 + CloudFront

El hosting estático de S3 es solo `http` y Entra ID exige `https`, así que S3 necesita CloudFront delante:

1. `npx ng build` en el frontend (sin `--base-href`) y sube el contenido de `dist/hotel-frontend-admin/browser/` a un
   bucket con *Block public access* activado.
2. **CloudFront → Create distribution** → origen: el bucket, con **Origin access control**; aplica la bucket policy
   que CloudFront te sugiere. *Default root object*: `index.html`. En **Error pages**, responde 403 y 404 con
   `/index.html` y código 200, para que funcionen las rutas de Angular.
3. Registra `https://<id>.cloudfront.net/redirect.html` y `https://<id>.cloudfront.net/` en la SPA de Entra ID y agrega
   `https://<id>.cloudfront.net` al CORS del API Gateway.

Si CloudFront no está disponible en tu Learner Lab, quédate con GitHub Pages.

### MySQL en RDS

1. **RDS → Create database → MySQL 8.4**, plantilla *Free tier* / `db.t3.micro`, misma VPC que la EC2, sin acceso
   público. En su security group permite el 3306 **solo** desde `hotel-backend-sg`.
2. Crea las tablas una vez (desde `~/hotel/hotel-infra`):
   `docker compose run --rm -T mysql mysql -h <endpoint-rds> -uadmin -p'<clave>' < ../hotel-ms-usuarios/database.sql`
3. En `.env` agrega `MYSQL_HOST=<endpoint-rds>`, `MYSQL_USER=admin` y su `MYSQL_PASSWORD`, y levanta sin el contenedor
   de MySQL: `docker compose up -d --build --no-deps ms-usuarios ms-reservas`.

## Problemas comunes

| Síntoma | Qué revisar |
| --- | --- |
| `503 Service Unavailable` desde API Gateway | EC2 detenida, security group sin 8081/8082, o la IP de la integración no es la elástica. |
| `401 Unauthorized` del API Gateway **con** token | Issuer o audience del JWT authorizer no coinciden, o el token es v1 (ver README del frontend, manifiesto). |
| `TOKEN_INVALIDO` desde un microservicio | Los valores de `.env` no son los de `hotel-bff-admin`. Tras cambiarlos: `docker compose up -d`. |
| Error de CORS en la consola del navegador | Falta tu origen exacto en el CORS del API Gateway. |
| `ERROR_INTERNO` en Usuarios | MySQL no está listo o falló el esquema: `docker compose logs mysql`. |
| `compose build requires buildx` | No se instaló Docker con `get.docker.com` en Ubuntu; instala `docker-buildx-plugin`. |
