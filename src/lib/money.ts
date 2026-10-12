export function cents(value: string): bigint {
  if (!/^\d{1,12}(\.\d{1,2})?$/.test(value)) throw new Error('invalidMoney');
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
}
export function decimal(value: bigint): string { return `${value / 100n}.${(value % 100n).toString().padStart(2, '0')}`; }
export function lineTotal(price: string, quantity: number): string {
  if (!Number.isSafeInteger(quantity) || quantity < 1 || quantity > 100000) throw new Error('invalidQuantity');
  return decimal(cents(price) * BigInt(quantity));
}
