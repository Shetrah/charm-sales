export function databaseError(error: { code?: string; message: string }): Error {
  if (error.code === 'PGRST106') return new Error('schemaNotExposed');
  if (error.code === 'PGRST202') return new Error('migrationMissing');
  return new Error(error.message);
}
export function authenticationError(error: { code?: string }): Error {
  if (error.code === 'invalid_credentials') return new Error('invalidCredentials');
  if (error.code === 'email_not_confirmed') return new Error('emailUnconfirmed');
  if (['over_request_rate_limit', 'over_email_send_rate_limit'].includes(error.code ?? '')) return new Error('authRateLimit');
  return new Error('authError');
}
