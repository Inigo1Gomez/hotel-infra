// Lambda "Post confirmation" del User Pool de huéspedes (F26: rol por defecto).
// Cognito la llama cuando un huésped confirma su cuenta con el código del correo, y aquí se lo agrega
// al grupo CLIENTE. Desde su siguiente login, el access_token trae "cognito:groups": ["CLIENTE"].
//
// Runtime: Node.js 22.x (el AWS SDK v3 ya viene incluido en la Lambda, no hay que instalar nada).
// Permiso del rol de la Lambda: cognito-idp:AdminAddUserToGroup sobre el User Pool.
import { AdminAddUserToGroupCommand, CognitoIdentityProviderClient } from '@aws-sdk/client-cognito-identity-provider';

const cliente = new CognitoIdentityProviderClient({});
const GRUPO = process.env.GRUPO_CLIENTE ?? 'CLIENTE';

export const handler = async (evento) => {
	// También se dispara al confirmar "olvidé mi contraseña": ahí el huésped ya está en el grupo.
	if (evento.triggerSource !== 'PostConfirmation_ConfirmSignUp') {
		return evento;
	}

	await cliente.send(new AdminAddUserToGroupCommand({
		UserPoolId: evento.userPoolId,
		Username: evento.userName,
		GroupName: GRUPO
	}));
	console.log(JSON.stringify({ evento: 'CLIENTE_ASIGNADO', usuario: evento.userName, grupo: GRUPO }));

	// Cognito espera recibir el mismo evento de vuelta.
	return evento;
};
