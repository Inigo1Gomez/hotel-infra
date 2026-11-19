# Cognito: cuentas de huésped

Los huéspedes se registran solos en un **User Pool de Cognito**. Admin y Operador siguen entrando con Entra ID.

| Quién | Proveedor | Rol | Rutas |
|---|---|---|---|
| Visitante | Ninguno | — | `/user/reservas` (reservar como invitado y consultar por código) |
| Huésped registrado | Cognito | Grupo `CLIENTE` | `/cliente/reservas` (mis reservas, reservar con cuenta, cancelar una propia) |
| Admin / Operador | Entra ID | App roles `ADMIN` / `EMPLOYEE` | `/reservas`, catálogo, KPIs, auditoría… |

El rol sale de **quién emitió el token**. Un access_token de Cognito no abre las rutas de Entra ID (tiene otro issuer y otras llaves), y aunque sea válido solo da el rol Cliente.

## 1. Crear el User Pool (consola de AWS → Cognito)

1. **Create user pool**. En el asistente nuevo elige **Single-page application (SPA)** y nómbralo `hotel-frontend-user`.
2. **Options for sign-in identifiers:** solo **Email**.
3. **Self-registration:** activado. **Required attributes for sign-up:** `email` y `name`.
4. **Return URL:** déjalo vacío. No se usa la Hosted UI: las pantallas son propias.
5. Crear. Luego, en el User Pool:
   - **Authentication methods → Password policy:** el valor por defecto (8 caracteres, con mayúscula, minúscula, número y símbolo). Es la misma regla que valida el frontend.
   - **Sign-up → Attribute verification:** verificar `email` por **código** (lo envía Cognito; con el correo por defecto alcanza para la demo, unos 50 por día).
6. **App clients →** el que se creó con el asistente:
   - **Client secret:** ninguno (cliente público: el navegador no puede guardar secretos).
   - **Authentication flows:** `ALLOW_USER_PASSWORD_AUTH` y `ALLOW_REFRESH_TOKEN_AUTH`.
   - **Token revocation:** activado (el logout revoca el refresh token).
   - Duración: access token de 60 min y refresh token de 30 días. Son los valores por defecto.
7. **Groups → Create group:** nombre `CLIENTE`.

Anota:
- **User pool ID**, por ejemplo `us-east-1_AbCdEf123`.
- **Client ID** del app client.
- **Issuer:** `https://cognito-idp.us-east-1.amazonaws.com/<User pool ID>`.

## 2. Lambda post-confirmación (rol por defecto, F26)

1. **Lambda → Create function:** nombre `hotel-cognito-post-confirmacion`, runtime **Node.js 22.x**.
2. Pega el contenido de [`post-confirmacion/index.mjs`](post-confirmacion/index.mjs) como `index.mjs` y luego **Deploy**.
3. **Configuration → Permissions →** el rol de ejecución → **Add permissions → Create inline policy**:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "cognito-idp:AdminAddUserToGroup",
       "Resource": "arn:aws:cognito-idp:us-east-1:<cuenta>:userpool/<User pool ID>"
     }]
   }
   ```
   En AWS Academy, si no te deja crear roles ni políticas, elige el rol existente `LabRole` al crear la función. Si después al confirmar una cuenta aparece `AccessDenied` en los logs de la Lambda, ese rol no tiene el permiso y hay que usar `COGNITO_EXIGIR_GRUPO=false`.
4. En el User Pool: **Extensions → Add Lambda trigger → Sign-up → Post confirmation trigger** y elige la función.

Desde ahí, cada huésped que confirma su cuenta queda en el grupo `CLIENTE`, y su access_token trae `"cognito:groups": ["CLIENTE"]`.

> Mientras la Lambda no exista, pon `COGNITO_EXIGIR_GRUPO=false` en el `.env` para que `ms-reservas` no exija el grupo.

## 3. Configurar los servicios

**hotel-infra/.env** (ms-reservas):
```
COGNITO_ISSUER=https://cognito-idp.us-east-1.amazonaws.com/<User pool ID>
COGNITO_CLIENT_ID=<Client ID>
COGNITO_EXIGIR_GRUPO=true
```

**hotel-frontend-user:** `.env` en local, o en GitHub: Settings → Secrets and variables → Actions → **Variables**:
```
VITE_COGNITO_REGION=us-east-1
VITE_COGNITO_CLIENT_ID=<Client ID>
```

## 4. Qué valida cada uno

El frontend envía el **access_token** como `Authorization: Bearer …` (T03). `hotel-ms-reservas` (`src/middlewares/cognitoMiddleware.ts`) valida:

| Validación | Por qué |
|---|---|
| Firma con las llaves del User Pool (`/.well-known/jwks.json`) y vigencia | Que lo emitió Cognito y no expiró |
| `iss` = el User Pool | Que es de nuestro pool, no de otro |
| `token_use` = `access` y `client_id` = el app client | El access_token no trae `aud`: Cognito pone el app client en `client_id` |
| `cognito:groups` contiene `CLIENTE` | El rol viaja en el token (T05) |

En la fase 11 el API Gateway agrega un **JWT authorizer de Cognito** en las rutas `/cliente/*`, con issuer igual al del pool y audience igual al Client ID. Valida lo mismo antes de llegar a la EC2.

## 5. Prueba completa (como pide la guía)

1. En la web de huéspedes, **Ingresar → Crea una**: nombre, email y contraseña.
2. Llega un código al correo y se ingresa en **Confirma tu email**. La Lambda asigna `CLIENTE`.
3. **Inicia sesión** y entra a **Mi cuenta**, que muestra el rol `CLIENTE`, el `sub` y el issuer de Cognito.
4. Presiona **Probar rutas**:
   - `GET /api/v1/cliente/reservas` → **200** (permitida)
   - `GET /api/v1/reservas` → **401** (bloqueada: es de Admin u Operador)
5. **Olvidé mi contraseña:** llega un código y con él se define una nueva.
6. **Cerrar sesión:** se borra la sesión del navegador y se revoca el refresh token en Cognito.
