import { supabase, supabaseKey, supabaseUrl } from './supabase';

export const DOCUMENT_TYPES = ['image/jpeg','image/png','image/webp','application/pdf'] as const;
export const MAX_DOCUMENT_BYTES = 20 * 1024 * 1024;
const IMAGE_MAX_EDGE = 2400;
const IMAGE_QUALITY = 0.88;

export function documentExtension(type: string) {
  if (type === 'application/pdf') return 'pdf';
  if (type === 'image/png') return 'png';
  if (type === 'image/webp') return 'webp';
  return 'jpg';
}

export function documentLabel(file: { name: string }) {
  return file.name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ').trim() || 'document';
}

export function formatBytes(value: number | null | undefined) {
  if (value == null) return '—';
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(0)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

export function validateDocument(file: File) {
  if (!DOCUMENT_TYPES.includes(file.type as (typeof DOCUMENT_TYPES)[number])) throw new Error('documentInvalid');
  if (!file.size || file.size > MAX_DOCUMENT_BYTES) throw new Error('documentTooLarge');
}

async function bitmap(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if ('createImageBitmap' in window) return createImageBitmap(file);
  return new Promise((resolve, reject) => {
    const image = new Image();
    const url = URL.createObjectURL(file);
    image.onload = () => { URL.revokeObjectURL(url); resolve(image); };
    image.onerror = () => { URL.revokeObjectURL(url); reject(new Error('documentInvalid')); };
    image.src = url;
  });
}

export async function prepareDocument(file: File): Promise<File> {
  validateDocument(file);
  if (!file.type.startsWith('image/')) return file;
  try {
    const source = await bitmap(file);
    const width = 'width' in source ? source.width : 0;
    const height = 'height' in source ? source.height : 0;
    if (!width || !height) return file;
    const scale = Math.min(1, IMAGE_MAX_EDGE / Math.max(width, height));
    const targetWidth = Math.max(1, Math.round(width * scale));
    const targetHeight = Math.max(1, Math.round(height * scale));
    const canvas = document.createElement('canvas');
    canvas.width = targetWidth;
    canvas.height = targetHeight;
    const context = canvas.getContext('2d');
    if (!context) return file;
    context.fillStyle = '#fff';
    context.fillRect(0, 0, targetWidth, targetHeight);
    context.drawImage(source as CanvasImageSource, 0, 0, targetWidth, targetHeight);
    if ('close' in source) source.close();
    const blob = await new Promise<Blob | null>(resolve => canvas.toBlob(resolve, 'image/jpeg', IMAGE_QUALITY));
    if (!blob || blob.size >= file.size) return file;
    const name = `${documentLabel(file)}.jpg`;
    return new File([blob], name, { type: 'image/jpeg', lastModified: file.lastModified });
  } catch {
    return file;
  }
}

export async function uploadPrivate(path: string, file: File, onProgress?: (percent: number) => void): Promise<void> {
  if (!supabase || !supabaseUrl || !supabaseKey) throw new Error('configuration');
  const key = supabaseKey;
  const { data: { session } } = await supabase.auth.getSession();
  if (!session?.access_token) throw new Error('sessionExpired');
  const endpoint = `${supabaseUrl.replace(/\/$/, '')}/storage/v1/object/charm-private/${path.split('/').map(encodeURIComponent).join('/')}`;
  await new Promise<void>((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open('POST', endpoint);
    request.setRequestHeader('apikey', key);
    request.setRequestHeader('Authorization', `Bearer ${session.access_token}`);
    request.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    request.setRequestHeader('x-upsert', 'false');
    request.upload.onprogress = event => { if (event.lengthComputable) onProgress?.(Math.round((event.loaded / event.total) * 100)); };
    request.onerror = () => reject(new Error('documentUploadFailed'));
    request.ontimeout = () => reject(new Error('documentUploadFailed'));
    request.onload = () => {
      if (request.status >= 200 && request.status < 300) { onProgress?.(100); resolve(); return; }
      const duplicate = request.status === 409 || /duplicate|already exists/i.test(request.responseText);
      if (duplicate) { onProgress?.(100); resolve(); return; }
      reject(new Error('documentUploadFailed'));
    };
    request.send(file);
  });
}

export async function openPrivateFile(path: string, seconds = 120, download?: string) {
  if (!supabase) throw new Error('configuration');
  const { data, error } = await supabase.storage.from('charm-private').createSignedUrl(path, seconds, download ? { download } : undefined);
  if (error) throw new Error('documentPreviewUnavailable');
  return data.signedUrl;
}
