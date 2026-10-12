import { describe,it,expect } from 'vitest';
import { reportingMonths, formatMoney, settlement } from '../src/lib/presentation';
describe('financial and monitoring presentation',()=>{
 it('builds six reporting months across a year boundary',()=>{expect(reportingMonths('2027-02')).toEqual(['2026-09','2026-10','2026-11','2026-12','2027-01','2027-02']);});
 it('keeps exact cents in monetary presentation',()=>{expect(formatMoney('999999999999.99','en')).toBe('KES 999,999,999,999.99');expect(formatMoney('49.3','zh')).toBe('KES 49.30');});
 it('distinguishes settled, partial, unpaid and overdue, including due-day boundaries',()=>{
  const row={balance:'39.30',paid:'10.00',due_date:'2026-10-12'};
  expect(settlement(row,'2026-10-12')).toBe('partPaid');expect(settlement(row,'2026-10-13')).toBe('overdue');
  expect(settlement({...row,balance:'0.00'},'2026-10-13')).toBe('settled');expect(settlement({...row,paid:'0'},'2026-10-12')).toBe('unpaid');
 });
});
