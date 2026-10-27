export const BUSINESS_TIME_ZONE = 'Africa/Nairobi';
export const BUSINESS_TIME_ZONE_LABEL = 'EAT';
export type Language = 'en' | 'zh';

const locale = (language: Language) => (language === 'zh' ? 'zh-CN' : 'en-GB');

function parts(value: Date | string | number) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error('invalidDate');
  const values: Record<string, string> = {};
  for (const part of new Intl.DateTimeFormat('en-GB', {
    timeZone: BUSINESS_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date)) {
    if (part.type !== 'literal') values[part.type] = part.value;
  }
  return values;
}

export function nairobiDate(date = new Date()) {
  const value = parts(date);
  return `${value.year}-${value.month}-${value.day}`;
}

export function nairobiTime(date = new Date()) {
  const value = parts(date);
  return `${value.hour}:${value.minute}:${value.second}`;
}

export function formatBusinessDateTime(value: string | Date | number | null | undefined, language: Language = 'en') {
  if (value === null || value === undefined || value === '') return '—';
  const formatted = new Intl.DateTimeFormat(locale(language), {
    timeZone: BUSINESS_TIME_ZONE,
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(new Date(value));
  return `${formatted} ${BUSINESS_TIME_ZONE_LABEL}`;
}

export function formatBusinessDate(value: string | Date | number | null | undefined, language: Language = 'en') {
  if (value === null || value === undefined || value === '') return '—';
  return new Intl.DateTimeFormat(locale(language), {
    timeZone: BUSINESS_TIME_ZONE,
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(new Date(value));
}

export function formatBusinessTime(value: string | Date | number | null | undefined) {
  if (value === null || value === undefined || value === '') return '—';
  const formatted = new Intl.DateTimeFormat('en-GB', {
    timeZone: BUSINESS_TIME_ZONE,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(new Date(value));
  return `${formatted} ${BUSINESS_TIME_ZONE_LABEL}`;
}

/** Value for `<input type="datetime-local">` in Kenyan business time. */
export function businessDateTimeInput(value: string | Date | number = new Date()) {
  const date = parts(value);
  return `${date.year}-${date.month}-${date.day}T${date.hour}:${date.minute}`;
}

/** Value for `<input type="date">` in Kenyan business time. */
export function businessDateInput(value: string | Date | number = new Date()) {
  const date = parts(value);
  return `${date.year}-${date.month}-${date.day}`;
}

function zoneOffset(instant: number) {
  const date = parts(instant);
  const asIfUtc = Date.UTC(Number(date.year), Number(date.month) - 1, Number(date.day), Number(date.hour), Number(date.minute), Number(date.second));
  return asIfUtc - instant;
}

/**
 * Parses a Kenya wall-clock value (`YYYY-MM-DDTHH:mm`) into an absolute
 * instant. The offset is read from Africa/Nairobi, not from the device or a
 * hardcoded number, so the browser timezone cannot change the business time.
 */
export function businessInputToInstant(value: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!match) throw new Error('invalid');
  const [, year, month, day, hour, minute, second = '00'] = match;
  const wall = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second));
  let instant = wall - zoneOffset(wall);
  instant = wall - zoneOffset(instant);
  instant = wall - zoneOffset(instant);
  const result = new Date(instant);
  if (Number.isNaN(result.getTime())) throw new Error('invalid');
  return result.toISOString();
}

export function addBusinessDays(date: string, days: number) {
  const next = new Date(`${date}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + days);
  return next.toISOString().slice(0, 10);
}

/** Monday-based week start, matching the reporting SQL. */
export function mondayOf(date: string) {
  const value = new Date(`${date}T00:00:00Z`);
  return addBusinessDays(date, -((value.getUTCDay() + 6) % 7));
}

export function periodBounds(period: 'daily' | 'weekly' | 'monthly', date: string) {
  if (period === 'daily') return { start: date, end: date };
  if (period === 'weekly') {
    const start = mondayOf(date);
    return { start, end: addBusinessDays(start, 6) };
  }
  const value = new Date(`${date}T00:00:00Z`);
  const start = `${value.getUTCFullYear()}-${String(value.getUTCMonth() + 1).padStart(2, '0')}-01`;
  const end = new Date(Date.UTC(value.getUTCFullYear(), value.getUTCMonth() + 1, 0)).toISOString().slice(0, 10);
  return { start, end };
}
