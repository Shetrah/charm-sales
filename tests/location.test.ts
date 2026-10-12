import {describe,it,expect,vi} from 'vitest';
import {captureLocation} from '../src/lib/location';
const position={coords:{latitude:-1.286389,longitude:36.817223,accuracy:12},timestamp:Date.now()} as GeolocationPosition;
const env=(getCurrentPosition:Geolocation['getCurrentPosition'])=>({secure:true,allowed:true,geolocation:{getCurrentPosition}});
describe('browser location acquisition',()=>{
 it('uses fresh coordinates and preserves reported accuracy',async()=>{
  const fn=vi.fn((success:PositionCallback)=>success(position));const point=await captureLocation(undefined,env(fn));
  expect(point).toEqual({latitude:-1.286389,longitude:36.817223,accuracy_m:12,fallbackUsed:false});
  expect(fn.mock.calls[0]?.[0]).toBeTypeOf('function');expect(fn).toHaveBeenCalledWith(expect.any(Function),expect.any(Function),{enableHighAccuracy:true,timeout:25000,maximumAge:0});
 });
 it('falls back after a precise-position timeout without inventing accuracy',async()=>{
  const fn=vi.fn().mockImplementationOnce((_success,error)=>error({code:3})).mockImplementationOnce(success=>success({...position,coords:{...position.coords,accuracy:1500}}));
  const stages:string[]=[];const point=await captureLocation(stage=>stages.push(stage),env(fn));
  expect(stages).toEqual(['precise','fallback']);expect(point.accuracy_m).toBe(1500);expect(point.fallbackUsed).toBe(true);
  expect(fn).toHaveBeenLastCalledWith(expect.any(Function),expect.any(Function),{enableHighAccuracy:false,timeout:20000,maximumAge:0});
 });
 it('does not retry denied permission and distinguishes a provider failure from a timeout',async()=>{
  const denied=vi.fn((_success,error)=>error({code:1}));await expect(captureLocation(undefined,env(denied))).rejects.toThrow('gpsPermissionDenied');expect(denied).toHaveBeenCalledTimes(1);
  await expect(captureLocation(undefined,env((_success,error)=>error!({code:2} as GeolocationPositionError)))).rejects.toThrow('gpsProviderUnavailable');
  await expect(captureLocation(undefined,env((_success,error)=>error!({code:3} as GeolocationPositionError)))).rejects.toThrow('gpsTimeout');
 });
 it('identifies insecure HTTP, policy restrictions and unsupported browsers before requesting',async()=>{
  const fn=vi.fn();await expect(captureLocation(undefined,{...env(fn),secure:false})).rejects.toThrow('gpsInsecure');
  await expect(captureLocation(undefined,{...env(fn),allowed:false})).rejects.toThrow('gpsPolicyBlocked');
  await expect(captureLocation(undefined,{secure:true,allowed:true,geolocation:undefined})).rejects.toThrow('gpsUnsupported');expect(fn).not.toHaveBeenCalled();
 });
});
