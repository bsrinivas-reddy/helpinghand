import {sendPublicError,reportInternal} from '../../utils/publicError.js';
import { Request, Response } from 'express';
import crypto from 'crypto';
import { issueRegistrationGrant } from '../../utils/registrationGrant.js';
import pool from '../../db/db.js';
import redisClient from '../../db/redisClient.js';
import { signAccessToken, signRefreshToken, verifyRefreshToken } from '../../utils/jwt.js';
import { GoogleUserProfile, verifyGoogleIdToken, getGoogleAuthUrl, exchangeCodeForProfile } from '../../services/googleAuth.service.js';
import { sendTwilioSms } from '../../services/twilioService.js';

// 1. Send OTP (with Rate Limiting & Crypto Random Generation)
export const sendOtp = async (req: Request, res: Response): Promise<void> => {
    try {
        const { phoneNumber, role } = req.body;
        if (role !== 'worker' && role !== 'employer') { res.status(400).json({success:false, error:'role_required'}); return; }
        if (!phoneNumber || typeof phoneNumber !== 'string') {
            res.status(400).json({ success: false, error: 'Valid phone number is required' });
            return;
        }

        const cleanedPhone = phoneNumber.trim();

        // Check Cooldown (60 seconds)
        const cooldown = await redisClient.get(`otp_cooldown:${cleanedPhone}`);
        if (cooldown) {
            res.status(429).json({
                success: false,
                error: 'Please wait at least 60 seconds before requesting another OTP'
            });
            return;
        }

        // Check Hourly Limit (Max 5 requests per hour)
        const hourlyAttempts = await redisClient.get(`otp_hourly:${cleanedPhone}`);
        if (hourlyAttempts && parseInt(hourlyAttempts) >= 5) {
            res.status(429).json({
                success: false,
                error: 'Too many OTP requests for this phone number. Please try again in an hour.'
            });
            return;
        }

        // Generate cryptographically secure 6-digit OTP
        const otp = crypto.randomInt(100000, 999999).toString();

        // Store OTP in Redis (5 minute validity)
        await redisClient.set(`otp:${role}:${cleanedPhone}`, otp, { EX: 300 });

        // Set 60s cooldown in Redis
        await redisClient.set(`otp_cooldown:${cleanedPhone}`, '1', { EX: 60 });

        // Increment hourly attempt counter
        await redisClient.incr(`otp_hourly:${cleanedPhone}`);
        await redisClient.expire(`otp_hourly:${cleanedPhone}`, 3600);

        // Reset failed verification count
        await redisClient.del(`otp_failed:${cleanedPhone}`);


        // Dispatch real SMS via Twilio SMS Gateway
        await sendTwilioSms({
            to: cleanedPhone,
            body: `Your Helping Hand verification code is: ${otp}. Valid for 5 minutes. Do not share this OTP with anyone.`
        });

        const responsePayload: any = {
            success: true,
            message: 'OTP generated and sent successfully',
            phoneNumber: cleanedPhone,
            role
        };

        // Only include plain OTP in response in non-production environments
        if (process.env.NODE_ENV !== 'production') {
            responsePayload.otp = otp;
        }

        res.status(200).json(responsePayload);
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 2. Verify OTP (with Brute-force Shield & JWT Issuance)
export const verifyOtp = async (req: Request, res: Response): Promise<void> => {
    try {
        const { phoneNumber, otp, role } = req.body;
        if (role !== 'worker' && role !== 'employer') {
            res.status(400).json({success:false, error:'role_required'}); return;
        }
        if (!phoneNumber || !otp) {
            res.status(400).json({ success: false, error: 'Phone number and OTP are required' });
            return;
        }

        const cleanedPhone = phoneNumber.trim();

        // Check failed attempts (lock after 5 failed attempts)
        const failedCount = await redisClient.get(`otp_failed:${cleanedPhone}`);
        if (failedCount && parseInt(failedCount) >= 5) {
            res.status(429).json({
                success: false,
                error: 'Too many incorrect attempts. This OTP is locked. Please request a new OTP.'
            });
            return;
        }

        const cachedOtp = await redisClient.get(`otp:${role}:${cleanedPhone}`);

        if (!cachedOtp) {
            res.status(400).json({ success: false, error: 'OTP has expired or was not requested' });
            return;
        }

        if (cachedOtp !== otp) {
            await redisClient.incr(`otp_failed:${cleanedPhone}`);
            await redisClient.expire(`otp_failed:${cleanedPhone}`, 300);
            res.status(400).json({ success: false, error: 'Invalid OTP code' });
            return;
        }

        // Atomically consume only the OTP just checked. Parallel/replayed verification
        // must not mint a second session or registration grant.
        const consumed = await redisClient.eval(
            "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end",
            { keys: [`otp:${role}:${cleanedPhone}`], arguments: [String(otp)] }
        );
        if (!consumed) { res.status(400).json({success:false, error:'OTP expired or already used'}); return; }
        await redisClient.del(`otp_failed:${cleanedPhone}`);
        const table = role === 'worker' ? 'workers' : 'employers';
        const idColumn = role === 'worker' ? 'worker_id' : 'employer_id';
        const existing = await pool.query(`SELECT * FROM ${table} WHERE phone_number = $1`, [cleanedPhone]);
        if (existing.rows.length) {
            const user = existing.rows[0];
            const payload = {userId:user[idColumn], role, phoneNumber:cleanedPhone};
            res.status(200).json({success:true, isNewUser:false, role, user,
                token:signAccessToken(payload), refreshToken:signRefreshToken(payload)});
            return;
        }
        const registrationGrant = await issueRegistrationGrant(cleanedPhone, role);
        res.status(200).json({success:true, isNewUser:true, role, phoneNumber:cleanedPhone,
            registrationGrant, expiresInSeconds:300, message:'Phone number verified. User registration required.'});
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// Both mobile and web call this only with an already verified provider profile.
const finishGoogleAuth = async (googleProfile: GoogleUserProfile, selectedRole: 'worker'|'employer', res:Response):Promise<void> => {
        const { googleId, email, fullName, avatarUrl } = googleProfile;

        if (selectedRole === 'employer') {
            // Find or create employer
            let empRes = await pool.query(
                'SELECT * FROM employers WHERE google_id = $1 OR email = $2',
                [googleId, email]
            );

            let employer;
            let isNewUser = false;

            if (empRes.rows.length > 0) {
                employer = empRes.rows[0];
                // Update Google info if needed
                if (!employer.google_id || !employer.avatar_url) {
                    const updateRes = await pool.query(
                        `UPDATE employers 
                         SET google_id = COALESCE(google_id, $1), 
                             avatar_url = COALESCE(avatar_url, $2),
                             full_name = COALESCE(full_name, $3)
                         WHERE employer_id = $4 RETURNING *`,
                        [googleId, avatarUrl, fullName, employer.employer_id]
                    );
                    employer = updateRes.rows[0];
                }
            } else {
                isNewUser = true;
                const insertRes = await pool.query(
                    `INSERT INTO employers (google_id, email, full_name, avatar_url)
                     VALUES ($1, $2, $3, $4)
                     RETURNING *`,
                    [googleId, email, fullName || 'Employer', avatarUrl]
                );
                employer = insertRes.rows[0];
            }

            const token = signAccessToken({
                userId: employer.employer_id,
                role: 'employer',
                email: employer.email
            });
            const refreshToken = signRefreshToken({
                userId: employer.employer_id,
                role: 'employer'
            });

            res.status(200).json({
                success: true,
                isNewUser,
                role: 'employer',
                user: employer,
                token,
                refreshToken
            });
            return;
        } else {
            // Worker role
            let wrkRes = await pool.query(
                'SELECT * FROM workers WHERE google_id = $1 OR email = $2',
                [googleId, email]
            );

            let worker;
            let isNewUser = false;

            if (wrkRes.rows.length > 0) {
                worker = wrkRes.rows[0];
                if (!worker.google_id || !worker.avatar_url) {
                    const updateRes = await pool.query(
                        `UPDATE workers 
                         SET google_id = COALESCE(google_id, $1), 
                             avatar_url = COALESCE(avatar_url, $2)
                         WHERE worker_id = $3 RETURNING *`,
                        [googleId, avatarUrl, worker.worker_id]
                    );
                    worker = updateRes.rows[0];
                }
            } else {
                isNewUser = true;
                const insertRes = await pool.query(
                    `INSERT INTO workers (google_id, email, avatar_url, worker_category)
                     VALUES ($1, $2, $3, 'GENERAL_LABOR')
                     RETURNING *`,
                    [googleId, email, avatarUrl]
                );
                worker = insertRes.rows[0];
            }

            const token = signAccessToken({
                userId: worker.worker_id,
                role: 'worker',
                email: worker.email
            });
            const refreshToken = signRefreshToken({
                userId: worker.worker_id,
                role: 'worker'
            });

            res.status(200).json({
                success: true,
                isNewUser,
                role: 'worker',
                user: worker,
                token,
                refreshToken
            });
            return;
        }

};
export const googleAuth = async (req:Request,res:Response):Promise<void> => {
    try {
        const {idToken,role}=req.body;
        if(!idToken || (role!=='worker'&&role!=='employer')) {res.status(400).json({success:false,error:'ID token and explicit role required'});return;}
        await finishGoogleAuth(await verifyGoogleIdToken(idToken),role,res);
    } catch (error: any) {
        reportInternal('Error in googleAuth:');
        res.status(401).json({success:false,error:'Google authentication failed'});
    }
};

// 4. Get Google OAuth Web Consent URL
export const getGoogleUrl = async(req:Request,res:Response):Promise<void> => {
    try {
        const role=req.query.role;
        if(role!=='worker'&&role!=='employer'){res.status(400).json({success:false,error:'Explicit role required'});return;}
        const state=crypto.randomBytes(32).toString('hex');
        const hash=crypto.createHash('sha256').update(state).digest('hex');
        await redisClient.set(`oauth_state:${hash}`,role,{EX:300});
        res.status(200).json({success:true,url:getGoogleAuthUrl(state)});
    }catch{res.status(503).json({success:false,error:'OAuth unavailable'});}
};
export const handleGoogleWebCallback=async(req:Request,res:Response):Promise<void>=>{
    try{
        const {code,state}=req.query;
        if(typeof code!=='string'||typeof state!=='string'||!/^[a-f0-9]{64}$/.test(state)){res.status(400).json({success:false,error:'Valid OAuth code and state required'});return;}
        const hash=crypto.createHash('sha256').update(state).digest('hex');
        const role=await redisClient.getDel(`oauth_state:${hash}`);
        if(role!=='worker'&&role!=='employer'){res.status(400).json({success:false,error:'OAuth state expired or already used'});return;}
        await finishGoogleAuth(await exchangeCodeForProfile(code),role,res);
    }catch{res.status(401).json({success:false,error:'Google authentication failed'});}
};

// 6. Refresh Access Token
export const refreshUserToken = async (req: Request, res: Response): Promise<void> => {
    try {
        const { refreshToken } = req.body;
        if (!refreshToken) {
            res.status(400).json({ success: false, error: 'Refresh token is required' });
            return;
        }

        const decoded = verifyRefreshToken(refreshToken);
        const newToken = signAccessToken({
            userId: decoded.userId,
            role: decoded.role
        });

        res.status(200).json({
            success: true,
            token: newToken
        });
    } catch (error: any) {
        res.status(401).json({ success: false, error: 'Invalid or expired refresh token' });
    }
};
