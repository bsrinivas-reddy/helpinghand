const bounded=(name:string,fallback:number,min:number,max:number):number=>{
    const raw=process.env[name];if(raw===undefined)return fallback;const n=Number(raw);
    if(!Number.isInteger(n)||n<min||n>max)throw new Error(`Invalid ${name}`);return n;
};
export const verificationConfig=()=>({pollMs:bounded('VERIFICATION_POLL_MS',60000,1000,300000),batch:bounded('VERIFICATION_BATCH',20,1,100),bindingSeconds:bounded('VERIFICATION_BINDING_SECONDS',86400,900,604800),staleSeconds:bounded('VERIFICATION_STALE_SECONDS',900,120,3600),providerTimeoutMs:bounded('VERIFICATION_PROVIDER_TIMEOUT_MS',15000,1000,30000)});
