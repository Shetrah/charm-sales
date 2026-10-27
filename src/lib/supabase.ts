import { createClient } from '@supabase/supabase-js';
import { databaseError } from './errors';
export const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
export const supabaseKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;
export const configured = !!supabaseUrl && !!supabaseKey;
export const supabase = configured ? createClient(supabaseUrl!, supabaseKey!, { db: { schema: 'charm' }, auth: { detectSessionInUrl: true, persistSession: true, autoRefreshToken: true } }) : null;
export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) throw new Error('configuration');
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw databaseError(error);
  return data as T;
}
