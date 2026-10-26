import {verificationConfig} from '../utils/verificationConfig.js';
import pool from '../db/db.js';
import {dispatchIvrCalls} from './ivrService.js';
import {transaction} from './shiftState.service.js';
// New completion code must persist this intent in its completion transaction.
// Kept for legacy internal callers, never accepts request timing/test controls.
export const scheduleAutomatedVerificationCall=async(shiftId:string):Promise<{scheduled:boolean;scheduledTime:Date}>=>{
    const when=new Date(Date.now()+5*60000);
    const result=await pool.query("UPDATE shifts SET verification_call_status = 'SCHEDULED', verification_scheduled_at = $1 WHERE shift_id = $2 AND status = 'COMPLETED' AND verification_call_status = 'NONE' RETURNING *",[when,shiftId]);
    return {scheduled:result.rows.length>0,scheduledTime:when};
};
let running=false;let stopRequested=false;
export const recoverDueVerification=async():Promise<void>=>{
    if(running)return;running=true;
    try {
        // Conservative: stale in-flight dispatch is ambiguous, NEVER redial.
        await pool.query("UPDATE shifts SET verification_call_status = 'UNKNOWN' WHERE verification_call_status = 'DISPATCHING' AND verification_scheduled_at < CURRENT_TIMESTAMP - ($1 * INTERVAL '1 second')",[verificationConfig().staleSeconds]);
        for(let i=0;i<verificationConfig().batch&&!stopRequested;i++){
            const shift=await transaction(async db=>{
                const result=await db.query("SELECT s.*, w.phone_number AS worker_phone,e.phone_number AS employer_phone FROM shifts s JOIN workers w ON w.worker_id=s.worker_id JOIN employers e ON e.employer_id=s.employer_id WHERE s.status='COMPLETED' AND s.verification_call_status='SCHEDULED' AND s.verification_scheduled_at<=CURRENT_TIMESTAMP ORDER BY s.verification_scheduled_at LIMIT 1 FOR UPDATE OF s SKIP LOCKED");
                if(!result.rows.length)return null;
                const row=result.rows[0];await db.query("UPDATE shifts SET verification_call_status='DISPATCHING',verification_scheduled_at=CURRENT_TIMESTAMP WHERE shift_id=$1 AND verification_call_status='SCHEDULED'",[row.shift_id]);return row;
            });
            if(!shift)break;
            try {await dispatchIvrCalls({shiftId:shift.shift_id,workerPhone:shift.worker_phone,employerPhone:shift.employer_phone,agreedWage:Number(shift.actual_cash_paid)});}
            catch {await pool.query("UPDATE shifts SET verification_call_status='UNKNOWN' WHERE shift_id=$1 AND verification_call_status='DISPATCHING'",[shift.shift_id]);}
        }
    } finally {running=false;}
};
export const startVerificationRecovery=():()=>Promise<void>=>{
    stopRequested=false;
    let stopped=false;let current:Promise<void>=Promise.resolve();
    const check=()=>{if(stopped||running)return;current=recoverDueVerification().catch(()=>console.error('Verification recovery unavailable'));};
    check();const timer=setInterval(check,verificationConfig().pollMs);timer.unref();
    return async()=>{stopped=true;stopRequested=true;clearInterval(timer);await current;};
};
