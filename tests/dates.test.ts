import { describe, expect, it } from 'vitest';
import { businessDateInput, businessDateTimeInput, businessInputToInstant, formatBusinessDate, formatBusinessDateTime, formatBusinessTime, mondayOf, nairobiDate, periodBounds } from '../src/lib/dates';

describe('Africa/Nairobi business time', () => {
 it('interprets business-date input in Nairobi, not device time', () => {
  expect(businessInputToInstant('2026-10-27T00:00')).toBe('2026-10-26T21:00:00.000Z');
  expect(businessInputToInstant('2026-10-27T14:30')).toBe('2026-10-27T11:30:00.000Z');
  expect(businessInputToInstant('2026-10-27T23:59:59')).toBe('2026-10-27T20:59:59.000Z');
 });
 it('round-trips a UTC instant through Kenyan wall-clock inputs without double conversion', () => {
  const instant = businessInputToInstant('2026-10-27T14:30');
  expect(businessDateTimeInput(instant)).toBe('2026-10-27T14:30');
  expect(businessDateInput(instant)).toBe('2026-10-27');
  expect(formatBusinessDateTime(instant)).toBe('27 Oct 2026, 14:30 EAT');
 });
 it('formats every display with an explicit 24-hour EAT label', () => {
  expect(formatBusinessDateTime('2026-10-27T20:59:59Z')).toBe('27 Oct 2026, 23:59 EAT');
  expect(formatBusinessDateTime('2026-10-27T21:00:00Z')).toBe('28 Oct 2026, 00:00 EAT');
  expect(formatBusinessTime('2026-10-27T21:00:00Z')).toBe('00:00 EAT');
  expect(formatBusinessDate('2026-10-27')).toBe('27 Oct 2026');
  expect(formatBusinessDateTime(null)).toBe('—');
 });
 it('assigns records around Kenyan midnight to the correct business date', () => {
  expect(nairobiDate(new Date('2026-10-27T20:59:59Z'))).toBe('2026-10-27');
  expect(nairobiDate(new Date('2026-10-27T21:00:00Z'))).toBe('2026-10-28');
  expect(businessDateTimeInput('2026-10-27T21:05:00Z')).toBe('2026-10-28T00:05');
  expect(businessDateInput('2026-10-27T21:05:00Z')).toBe('2026-10-28');
 });
 it('builds Monday-based weekly and calendar monthly periods', () => {
  expect(mondayOf('2026-11-01')).toBe('2026-10-26');
  expect(periodBounds('daily', '2026-10-27')).toEqual({ start: '2026-10-27', end: '2026-10-27' });
  expect(periodBounds('weekly', '2026-11-01')).toEqual({ start: '2026-10-26', end: '2026-11-01' });
  expect(periodBounds('monthly', '2026-10-15')).toEqual({ start: '2026-10-01', end: '2026-10-31' });
  expect(periodBounds('monthly', '2028-02-10')).toEqual({ start: '2028-02-01', end: '2028-02-29' });
 });
});
