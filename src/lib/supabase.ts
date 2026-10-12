import { createClient } from '@supabase/supabase-js';
import { databaseError } from './errors';
export const configured = !!import.meta.env.VITE_SUPABASE_URL && !!import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
export const supabase = configured ? createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY, { db: { schema: 'charm' }, auth: { detectSessionInUrl: true, persistSession: true, autoRefreshToken: true } }) : null;
export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) throw new Error('configuration');
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw databaseError(error);
  return data as T;
}
