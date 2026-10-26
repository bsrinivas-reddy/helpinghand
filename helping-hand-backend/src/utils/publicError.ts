import crypto from 'crypto';import {Response} from 'express';import {FlowError} from '../services/shiftState.service.js';
export const reportInternal=(context:string,requestId=crypto.randomUUID()):string=>{console.error({event:'internal_error',context,requestId});return requestId;};
export const sendPublicError=(res:Response,error:unknown,context:string):void=>{
    if(error instanceof FlowError&&[400,401,403,404,409,429].includes(error.status)){
        res.status(error.status).json({success:false,error:error.message});return;
    }
    const requestId=reportInternal(context);res.status(500).json({success:false,error:'Internal server error',message:'Internal server error',code:'INTERNAL_ERROR',requestId});
};
