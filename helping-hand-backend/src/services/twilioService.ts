import {verificationConfig} from '../utils/verificationConfig.js';
import 'dotenv/config';

export interface TwilioSmsParams {
    to: string;
    body: string;
}

export interface TwilioCallParams {
    to: string;
    shiftId: string;
    role: 'worker' | 'employer';
    agreedWage: number;
    callbackBaseUrl?: string;
    dispatchNonce: string;
}

const formatE164 = (phone: string): string => {
    const cleaned = phone.replace(/[^\d+]/g, '');
    if (cleaned.startsWith('+')) return cleaned;
    // Default to +91 (India) if 10-digit number
    if (cleaned.length === 10) return `+91${cleaned}`;
    return `+${cleaned}`;
};

/**
 * Send SMS via Twilio REST API
 */
export const sendTwilioSms = async (params: TwilioSmsParams): Promise<{ success: boolean; sid?: string; simulated?: boolean }> => {
    const accountSid = process.env.TWILIO_ACCOUNT_SID;
    const authToken = process.env.TWILIO_AUTH_TOKEN;
    const fromNumber = process.env.TWILIO_PHONE_NUMBER;

    const formattedTo = formatE164(params.to);

    if (!accountSid || !authToken || !fromNumber) {
        if (process.env.NODE_ENV === 'production') {
            throw new Error('Twilio credentials (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER) must be configured in production');
        }
        console.log('SMS simulation used');
        return { success: true, simulated: true };
    }

    const authHeader = 'Basic ' + Buffer.from(`${accountSid}:${authToken}`).toString('base64');
    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`;

    const bodyParams = new URLSearchParams({
        To: formattedTo,
        From: fromNumber,
        Body: params.body
    });

    const response = await fetch(endpoint, {
        signal: AbortSignal.timeout(verificationConfig().providerTimeoutMs),
        method: 'POST',
        headers: {
            'Authorization': authHeader,
            'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: bodyParams.toString()
    });

    const data = await response.json();

    if (!response.ok) {
        console.error('Telephony request rejected');
        throw new Error(`Twilio SMS delivery failed: ${data.message || response.statusText}`);
    }

    console.log('SMS accepted by provider');
    return { success: true, sid: data.sid };
};

/**
 * Initiate Outbound IVR Telephony Call with Gather DTMF via Twilio
 */
export const makeTwilioIvrCall = async (params: TwilioCallParams): Promise<{ success: boolean; sid?: string; simulated?: boolean }> => {
    const accountSid = process.env.TWILIO_ACCOUNT_SID;
    const authToken = process.env.TWILIO_AUTH_TOKEN;
    const fromNumber = process.env.TWILIO_PHONE_NUMBER;
    const callbackBase = params.callbackBaseUrl || process.env.TWILIO_CALLBACK_BASE_URL;
    if (!callbackBase) throw new Error('Configured external HTTPS callback URL required');
    const external=new URL(callbackBase);
    if(external.protocol!=='https:'||external.pathname!=='/'||external.search||external.hash||external.username||external.password)throw new Error('Invalid external callback origin');

    const formattedTo = formatE164(params.to);
    const callbackUrl = `${new URL(callbackBase).origin}/api/${params.role}/shifts/${params.shiftId}/ivr-callback?dispatch=${params.dispatchNonce}`;

    // Construct accessible TwiML with Speech & DTMF Gather
    const promptText = params.role === 'worker'
        ? `Helping Hand verification call. Did you receive the physical cash payment of rupees ${params.agreedWage}? Press 1 to confirm, or 2 to report a dispute.`
        : `Helping Hand verification call. Did you pay the physical cash payment of rupees ${params.agreedWage} to the worker? Press 1 to confirm, or 2 to report a dispute.`;

    const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
    <Gather numDigits="1" action="${callbackUrl.replaceAll('&', '&amp;')}" method="POST" timeout="10">
        <Say voice="Polly.Aditi" language="en-IN">${promptText}</Say>
    </Gather>
    <Say voice="Polly.Aditi" language="en-IN">We did not receive any keypress. This shift remains pending verification. Goodbye.</Say>
</Response>`;

    if (!accountSid || !authToken || !fromNumber) {
        if (process.env.NODE_ENV === 'production') {
            throw new Error('Twilio Voice credentials must be configured in production environment');
        }
        console.log('Voice simulation used');
        return { success: true, simulated: true };
    }

    const authHeader = 'Basic ' + Buffer.from(`${accountSid}:${authToken}`).toString('base64');
    const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Calls.json`;

    const bodyParams = new URLSearchParams({
        To: formattedTo,
        From: fromNumber,
        Twiml: twiml
    });

    const response = await fetch(endpoint, {
        signal: AbortSignal.timeout(verificationConfig().providerTimeoutMs),
        method: 'POST',
        headers: {
            'Authorization': authHeader,
            'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: bodyParams.toString()
    });

    const data = await response.json();

    if (!response.ok) {
        console.error('Telephony request rejected');
        throw new Error(`Twilio Voice call failed: ${data.message || response.statusText}`);
    }

    console.log('Voice accepted by provider');
    return { success: true, sid: data.sid };
};
