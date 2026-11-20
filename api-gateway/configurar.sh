#!/usr/bin/env bash
# Configura el API Gateway (HTTP API "hotel-api") para el EFT. Se ejecuta en AWS CloudShell.
# Se puede correr más de una vez: crea lo que falta y actualiza lo que ya existe.
#
#   Públicas (sin token) .... ver catálogo, reservar como invitado, consultar reserva con código + email
#   Cognito (huésped) ....... /reservas/api/v1/cliente/*: mis reservas, reservar con cuenta, cancelar una propia
#   Entra ID (Admin/Op.) .... todo lo demás: reservas internas, usuarios, editar catálogo, reportes, auditoría, admin de colas y tópicos
#
# API Gateway elige la ruta más específica, así que /reservas/api/v1/cliente/{proxy+} gana sobre /reservas/{proxy+}.
export AWS_PAGER=""

API=v5bzsbqtk7
IP=34.201.213.123                 # IP pública de la EC2 (cambia si se detiene y no tiene Elastic IP)
SG=sg-07d00bec52189dcc4           # Security Group de la EC2
ENTRA=hspijl                      # authorizer JWT de Entra ID que ya existía
ISSUER=https://cognito-idp.us-east-1.amazonaws.com/us-east-1_kmJvMVUlE
CLIENTE_COGNITO=507miqsvr10ks1fdus0uhd5sus

echo "== Puertos de los microservicios nuevos en el Security Group"
for puerto in 8085 8086 8087 8088; do
  if aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port $puerto --cidr 0.0.0.0/0 > /dev/null 2>&1; then
    echo "abierto   $puerto"
  else
    echo "ya estaba $puerto"
  fi
done

echo "== Authorizer JWT de Cognito"
# El access_token de Cognito no trae "aud": API Gateway compara la audiencia con el claim client_id.
COGNITO=$(aws apigatewayv2 get-authorizers --api-id $API --query "Items[?Name=='cognito-huespedes'].AuthorizerId | [0]" --output text)
if [ "$COGNITO" = "None" ]; then
  COGNITO=$(aws apigatewayv2 create-authorizer --api-id $API --name cognito-huespedes --authorizer-type JWT \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration Audience=$CLIENTE_COGNITO,Issuer=$ISSUER --query AuthorizerId --output text)
  echo "creado    $COGNITO"
else
  echo "ya estaba $COGNITO"
fi

# Devuelve el id de la integración HTTP_PROXY con esa URI (la crea si no existe).
integracion() {
  local uri=$1 id
  id=$(aws apigatewayv2 get-integrations --api-id $API \
    --query "Items[?IntegrationUri=='$uri' && IntegrationMethod=='ANY'].IntegrationId" --output text | tr -s '[:space:]' '\n' | grep -v '^None$' | head -1)
  if [ -z "$id" ]; then
    id=$(aws apigatewayv2 create-integration --api-id $API --integration-type HTTP_PROXY --integration-method ANY \
      --integration-uri "$uri" --payload-format-version 1.0 --query IntegrationId --output text)
  fi
  echo "$id"
}

# Crea o actualiza una ruta. $3 = NONE (pública) o el id de un authorizer JWT.
ruta() {
  local clave=$1 destino=$2 autorizador=$3 id
  local auth=(--authorization-type NONE)
  [ "$autorizador" != "NONE" ] && auth=(--authorization-type JWT --authorizer-id "$autorizador")
  # La CLI pagina los resultados (de a 25): se juntan todas las páginas y se descartan las vacías.
  id=$(aws apigatewayv2 get-routes --api-id $API --query "Items[?RouteKey=='$clave'].RouteId" --output text | tr -s '[:space:]' '\n' | grep -v '^None$' | head -1)
  if [ -z "$id" ]; then
    aws apigatewayv2 create-route --api-id $API --route-key "$clave" --target "integrations/$destino" "${auth[@]}" > /dev/null && echo "creada    $clave"
  else
    aws apigatewayv2 update-route --api-id $API --route-id "$id" --target "integrations/$destino" "${auth[@]}" > /dev/null && echo "ok        $clave"
  fi
}

echo "== Integraciones"
I_USER=$(integracion "http://$IP:8081/api/v1/user/{proxy}")
I_CLIENTE=$(integracion "http://$IP:8081/api/v1/cliente/{proxy}")
I_CATALOGO=$(integracion "http://$IP:8088/{proxy}")
I_REPORTES=$(integracion "http://$IP:8086/{proxy}")
I_AUDITORIA=$(integracion "http://$IP:8087/{proxy}")
I_RABBITMQ=$(integracion "http://$IP:8083/{proxy}")
I_KAFKA=$(integracion "http://$IP:8085/{proxy}")
echo "listas"

echo "== Rutas públicas"
# POST /reservas/api/v1/user/reservas (reservar como invitado) ya existía y se mantiene.
ruta "GET /reservas/api/v1/user/{proxy+}" "$I_USER" NONE          # consultar con código + email
ruta "GET /catalogo/{proxy+}" "$I_CATALOGO" NONE                  # hoteles, habitaciones y disponibilidad

echo "== Rutas de huésped (Cognito)"
for metodo in GET POST PATCH; do
  ruta "$metodo /reservas/api/v1/cliente/{proxy+}" "$I_CLIENTE" "$COGNITO"
done

echo "== Rutas internas (Entra ID)"
for metodo in POST PATCH; do
  ruta "$metodo /catalogo/{proxy+}" "$I_CATALOGO" "$ENTRA"
done
for servicio in reportes:$I_REPORTES auditoria:$I_AUDITORIA rabbitmq:$I_RABBITMQ kafka:$I_KAFKA; do
  for metodo in GET POST PATCH DELETE; do
    ruta "$metodo /${servicio%%:*}/{proxy+}" "${servicio#*:}" "$ENTRA"
  done
done

echo "== CORS (agrega la web de huéspedes en local: http://localhost:5173)"
aws apigatewayv2 update-api --api-id $API --cors-configuration '{
  "AllowOrigins": ["https://inigo1gomez.github.io", "http://localhost:4200", "http://localhost:5173"],
  "AllowHeaders": ["authorization", "content-type"],
  "AllowMethods": ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
  "MaxAge": 300
}' > /dev/null && echo "ok"

echo "== Prueba rápida (el stage \$default se despliega solo)"
URL=https://$API.execute-api.us-east-1.amazonaws.com
sleep 3
printf "catálogo público           -> %s (esperado 200)\n" "$(curl -s -o /dev/null -w '%{http_code}' $URL/catalogo/api/v1/catalogo/hoteles)"
printf "consulta sin email         -> %s (esperado 400)\n" "$(curl -s -o /dev/null -w '%{http_code}' $URL/reservas/api/v1/user/reservas/RES-X)"
printf "mis reservas sin token     -> %s (esperado 401)\n" "$(curl -s -o /dev/null -w '%{http_code}' $URL/reservas/api/v1/cliente/reservas)"
printf "reservas internas sin token-> %s (esperado 401)\n" "$(curl -s -o /dev/null -w '%{http_code}' $URL/reservas/api/v1/reservas)"
printf "auditoría sin token        -> %s (esperado 401)\n" "$(curl -s -o /dev/null -w '%{http_code}' $URL/auditoria/api/v1/auditoria)"
