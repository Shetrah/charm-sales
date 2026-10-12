export type LocationPoint={latitude:number;longitude:number;accuracy_m:number;fallbackUsed:boolean};
export type CaptureStage='precise'|'fallback';
type Environment={secure:boolean;allowed:boolean;geolocation:Pick<Geolocation,'getCurrentPosition'>|undefined};
function environment():Environment{
 const doc=typeof document==='undefined'?null:document as Document & {permissionsPolicy?:{allowsFeature:(feature:string)=>boolean};featurePolicy?:{allowsFeature:(feature:string)=>boolean}};
 const policy=doc?.permissionsPolicy??doc?.featurePolicy;
 return {secure:globalThis.isSecureContext!==false,allowed:policy?.allowsFeature('geolocation')!==false,geolocation:typeof navigator==='undefined'?undefined:navigator.geolocation};
}
export async function captureLocation(onStage?:(stage:CaptureStage)=>void,env=environment()):Promise<LocationPoint>{
 if(!env.secure)throw new Error('gpsInsecure');
 if(!env.allowed)throw new Error('gpsPolicyBlocked');
 if(!env.geolocation)throw new Error('gpsUnsupported');
 const request=(high:boolean):Promise<GeolocationPosition>=>new Promise((resolve,reject)=>env.geolocation!.getCurrentPosition(resolve,reject,{enableHighAccuracy:high,timeout:high?25000:20000,maximumAge:0}));
 let position:GeolocationPosition;let fallbackUsed=false;
 onStage?.('precise');
 try{position=await request(true);}catch(error){
  if((error as GeolocationPositionError).code===1)throw new Error('gpsPermissionDenied');
  fallbackUsed=true;onStage?.('fallback');
  try{position=await request(false);}catch(second){const code=(second as GeolocationPositionError).code;throw new Error(code===1?'gpsPermissionDenied':code===3?'gpsTimeout':'gpsProviderUnavailable');}
 }
 const {latitude,longitude,accuracy}=position.coords;
 if(![latitude,longitude,accuracy].every(Number.isFinite)||latitude < -90||latitude > 90||longitude < -180||longitude > 180||accuracy<0||accuracy>100000)throw new Error('invalidLocation');
 return {latitude,longitude,accuracy_m:accuracy,fallbackUsed};
}
