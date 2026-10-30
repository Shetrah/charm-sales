import { useQuery } from '@tanstack/react-query';
import { documentExtension, openPrivateFile, prepareDocument, uploadPrivate } from './documents';
import { rpc } from './supabase';

export type MediaKind = 'staff' | 'products';

const saveFunction: Record<MediaKind, string> = { staff: 'save_staff_photo', products: 'save_product_image' };
const idParameter: Record<MediaKind, string> = { staff: 'p_id', products: 'p_product' };

export async function attachMedia(kind: MediaKind, id: number, file: File, onProgress?: (percent: number) => void) {
 const prepared = await prepareDocument(file);
 if (!prepared.type.startsWith('image/')) throw new Error('documentInvalid');
 const path = `${kind}/${id}/${crypto.randomUUID()}.${documentExtension(prepared.type)}`;
 await uploadPrivate(path, prepared, onProgress);
 await rpc(saveFunction[kind], { [idParameter[kind]]: id, p_path: path });
 return path;
}

export async function clearMedia(kind: MediaKind, id: number) {
 await rpc(saveFunction[kind], { [idParameter[kind]]: id, p_path: '' });
}

export function useMediaUrl(path?: string | null) {
 const query = useQuery({
  queryKey: ['media', path],
  queryFn: () => openPrivateFile(path as string, 900),
  enabled: !!path,
  staleTime: 5 * 60 * 1000,
  gcTime: 30 * 60 * 1000,
  retry: 1,
 });
 return query.data;
}
