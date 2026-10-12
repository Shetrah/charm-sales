import { describe, expect, it } from 'vitest';
import { authenticationError, databaseError } from '../src/lib/errors';
import { translatedError, translations } from '../src/i18n';
describe('Supabase setup and authentication feedback',()=>{
 it('explains PGRST106 in both languages instead of confusing it with account mapping',()=>{
  const error=databaseError({code:'PGRST106',message:'Invalid schema: charm'});
  expect(error.message).toBe('schemaNotExposed');
  for(const index of [0,1])expect(translatedError(error,key=>translations[key as keyof typeof translations][index])).toContain('charm');
 });
 it('distinguishes missing migrations and Auth failures',()=>{
  expect(databaseError({code:'PGRST202',message:'not found'}).message).toBe('migrationMissing');
  expect(authenticationError({code:'invalid_credentials'}).message).toBe('invalidCredentials');
  expect(authenticationError({code:'email_not_confirmed'}).message).toBe('emailUnconfirmed');
  expect(authenticationError({code:'over_request_rate_limit'}).message).toBe('authRateLimit');
  expect(databaseError({message:'forbidden'}).message).toBe('forbidden');
 });
});
