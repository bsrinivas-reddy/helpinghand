import {Request,Response,NextFunction} from 'express';
import twilio from 'twilio';
import crypto from 'crypto';
import redis from '../db/redisClient.js';
export const dispatchBindingKey = (nonce:string):string => `ivr_binding:${crypto.createHash('sha256').update(nonce).digest('hex')}`;
export const validateIvrCallback = (role:'worker'|'employer') => async(req:Request,res:Response,next:NextFunction):Promise<void> => {
    try {
        const base=process.env.TWILIO_CALLBACK_BASE_URL;
        const token=process.env.TWILIO_AUTH_TOKEN;
        const account=process.env.TWILIO_ACCOUNT_SID;
        if(!base||!token||!account) {res.status(503).json({success:false,error:'Callback verification unavailable'});return;}
        const configured=new URL(base);
        if(configured.protocol!=='https:'||configured.username||configured.password||configured.search||configured.hash||configured.pathname!=='/')throw new Error('Invalid callback base');
        if(!req.is('application/x-www-form-urlencoded')){res.status(415).json({success:false,error:'Expected form callback'});return;}
        // Configured external origin, never untrusted proxy/Host headers. Preserve
        // original URL encoding/query exactly as Twilio signed it.
        const exactUrl=configured.origin+req.originalUrl;
        const signature=req.get('x-twilio-signature');
        if(!signature||!twilio.validateRequest(token,signature,exactUrl,req.body)){res.status(403).json({success:false,error:'Invalid callback signature'});return;}
        const nonce=req.query.dispatch;
        if(typeof nonce!=='string'||!/^[a-f0-9]{64}$/.test(nonce)||req.body.AccountSid!==account||!/^CA[a-fA-F0-9]{32}$/.test(req.body.CallSid??'')||!['1','2'].includes(req.body.Digits)){res.status(403).json({success:false,error:'Invalid callback binding'});return;}
        const raw=await redis.get(dispatchBindingKey(nonce));
        if(!raw){res.status(403).json({success:false,error:'Callback binding unavailable'});return;}
        const binding=JSON.parse(raw);
        if(binding.shiftId!==req.params.shiftId||binding.role!==role||binding.to!==req.body.To||(binding.callSid&&binding.callSid!==req.body.CallSid)){res.status(403).json({success:false,error:'Invalid callback binding'});return;}
        // Bind the first signed callback SID atomically when the provider response
        // has not yet arrived. A later callback with a different SID fails closed.
        const bound=await redis.eval("local raw=redis.call('GET',KEYS[1]); if not raw then return 0 end; local b=cjson.decode(raw); if b.callSid and b.callSid~=ARGV[1] then return 0 end; b.callSid=ARGV[1]; redis.call('SET',KEYS[1],cjson.encode(b),'KEEPTTL'); return 1",{keys:[dispatchBindingKey(nonce)],arguments:[req.body.CallSid]});
        if(!bound){res.status(403).json({success:false,error:'Callback binding changed'});return;}
        res.locals.ivrRole=role;next();
    } catch {res.status(503).json({success:false,error:'Callback verification unavailable'});}
};
