import {sendPublicError,reportInternal} from '../../utils/publicError.js';
import { initiateCash, completeCash } from '../../services/cashHandshake.service.js';
import { transitionWorkerShift, FlowError, transaction } from '../../services/shiftState.service.js';
import { consumeRegistrationGrant } from '../../utils/registrationGrant.js';
import { requireActor, requireOwnPath, requireOwnedShift } from '../../utils/ownership.js';
import { Request, Response } from 'express';
import pool from '../../db/db.js';
import redisClient from '../../db/redisClient.js';
import { REDIS_WORKERS_GEO_KEY } from '../../utils/constants.js';
import { processIvrKeypress } from '../../services/ivrService.js';
import { signAccessToken, signRefreshToken } from '../../utils/jwt.js';

// Utility helper to synchronize worker availability based on current shifts status
export const syncWorkerAvailability = async (workerId: string): Promise<boolean> => {
    try {
        const activeShiftsRes = await pool.query(
            `SELECT COUNT(*) FROM shifts 
             WHERE worker_id = $1 AND status IN ('ACCEPTED', 'ACTIVE')`,
            [workerId]
        );
        const hasActiveShift = parseInt(activeShiftsRes.rows[0].count) > 0;
        if (!hasActiveShift) {
            const current = await pool.query('SELECT is_available FROM workers WHERE worker_id = $1', [workerId]);
            return current.rows[0]?.is_available === true;
        }
        await pool.query('UPDATE workers SET is_available = false WHERE worker_id = $1', [workerId]);
        await redisClient.zRem(REDIS_WORKERS_GEO_KEY, workerId);
        return false;
    } catch (err) {
        reportInternal('Error in syncWorkerAvailability:');
        return false;
    }
};

// 1. Worker Registration (from authController.ts)
export const registerWorker = async (req: Request, res: Response): Promise<void> => {
    try {
        const { phoneNumber, workerCategory, workerSubCategory } = req.body;
        if (!phoneNumber || !workerCategory) {
            res.status(400).json({
                success: false,
                error: 'phoneNumber and workerCategory are required'
            });
            return;
        }

        const cleanedPhone = phoneNumber.trim();
        if (!await consumeRegistrationGrant(req.body.registrationGrant, cleanedPhone, 'worker')) {
            res.status(401).json({success:false, error:'Valid registration grant required'}); return;
        }
        const existing = await pool.query('SELECT 1 FROM workers WHERE phone_number = $1', [cleanedPhone]);
        if (existing.rows.length) { res.status(409).json({success:false, error:'Account already exists; sign in'}); return; }


        const result = await pool.query(
            `INSERT INTO workers (phone_number, worker_category, worker_sub_category, is_available)
             VALUES ($1, $2, $3, false)
             RETURNING *`,
            [cleanedPhone, workerCategory.trim(), workerSubCategory ? workerSubCategory.trim() : null]
        );

        const user = result.rows[0];
        const token = signAccessToken({
            userId: user.worker_id,
            role: 'worker',
            phoneNumber: cleanedPhone,
            email: user.email
        });
        const refreshToken = signRefreshToken({
            userId: user.worker_id,
            role: 'worker',
            phoneNumber: cleanedPhone,
            email: user.email
        });

        res.status(201).json({
            success: true,
            role: 'worker',
            token,
            refreshToken,
            user
        });
    } catch (error: any) {
        if (error.code === '23505') { res.status(409).json({success:false, error:'Account already exists; sign in'}); return; }
        sendPublicError(res,error,'controller');
    }
};

// 2. Supply Status / Availability (from supplyController.ts)
export const toggleAvailability=async(req:Request,res:Response):Promise<void>=>{
    try{
        const actor=requireActor(req,res,'worker');if(!actor)return;
        const {isAvailable,lat,lng}=req.body;
        if(typeof isAvailable!=='boolean'||(lat!==undefined&&(!Number.isFinite(lat)||lat < -90||lat>90))||(lng!==undefined&&(!Number.isFinite(lng)||lng < -180||lng>180))){res.status(400).json({success:false,error:'Valid availability and coordinates required'});return;}
        const worker=await transaction(async db=>{
            const found=await db.query('SELECT * FROM workers WHERE worker_id=$1 FOR UPDATE',[actor]);if(!found.rows.length)throw new FlowError(404,'Worker not found');
            const busy=await db.query("SELECT shift_id FROM shifts WHERE worker_id=$1 AND status IN ('ACCEPTED','ACTIVE')",[actor]);
            if(isAvailable&&busy.rows.length)throw new FlowError(409,'Worker has accepted or active work');
            const result=await db.query('UPDATE workers SET is_available=$1,last_known_lat=COALESCE($2,last_known_lat),last_known_lng=COALESCE($3,last_known_lng) WHERE worker_id=$4 RETURNING *',[isAvailable,lat??null,lng??null,actor]);return result.rows[0];
        });
        if(!isAvailable)await redisClient.zRem(REDIS_WORKERS_GEO_KEY,actor);
        else if(worker.last_known_lat!=null&&worker.last_known_lng!=null)await redisClient.geoAdd(REDIS_WORKERS_GEO_KEY,{latitude:Number(worker.last_known_lat),longitude:Number(worker.last_known_lng),member:actor});
        res.status(200).json({success:true,isAvailable:worker.is_available,worker});
    }catch(error:any){sendPublicError(res,error,'controller');}
};

export const updateLocation = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        const workerId = actor;
        const { lat, lng } = req.body;
        if (!workerId || lat === undefined || lng === undefined) {
            res.status(400).json({
                success: false,
                error: 'workerId, lat, and lng are required'
            });
            return;
        }

        const numericLat = Number(lat);
        const numericLng = Number(lng);

        if (!Number.isFinite(numericLat) || !Number.isFinite(numericLng) || numericLat < -90 || numericLat > 90 || numericLng < -180 || numericLng > 180) {
            res.status(400).json({ success: false, error: 'lat and lng must be valid numbers' });
            return;
        }

        const result = await pool.query(
            `UPDATE workers 
             SET last_known_lat = $1, last_known_lng = $2 
             WHERE worker_id = $3 
             RETURNING worker_id, is_available`,
            [numericLat, numericLng, workerId]
        );

        if (result.rows.length === 0) {
            res.status(404).json({ success: false, error: 'Worker not found' });
            return;
        }

        const worker = result.rows[0];

        if (worker.is_available) {
            await redisClient.geoAdd(REDIS_WORKERS_GEO_KEY, {
                longitude: numericLng,
                latitude: numericLat,
                member: workerId
            });
        }

        res.status(200).json({
            success: true,
            message: 'Location updated successfully',
            workerId,
            lat: numericLat,
            lng: numericLng
        });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

export const getWorkerStatus = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        if (!requireOwnPath(res, req.params.workerId, actor)) return;
        const { workerId } = req.params;
        const targetWorkerId = Array.isArray(workerId) ? workerId[0] : workerId;
        const result = await pool.query('SELECT * FROM workers WHERE worker_id = $1', [targetWorkerId]);

        if (result.rows.length === 0) {
            res.status(404).json({ success: false, error: 'Worker not found' });
            return;
        }

        res.status(200).json({ success: true, worker: result.rows[0] });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 3. Worker Shift Management (from shiftController.ts)
export const acceptShift = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker'); if (!actor) return;
        const shift = await transitionWorkerShift(String(req.params.shiftId), actor, 'ACCEPTED');
        // Cache removal is repeatable; SQL transaction already marked worker offline.
        await redisClient.zRem(REDIS_WORKERS_GEO_KEY, actor);
        res.status(200).json({success:true, shift});
    } catch (error: any) { sendPublicError(res,error,'controller'); }
};

export const startShift = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker'); if (!actor) return;
        const shift = await transitionWorkerShift(String(req.params.shiftId), actor, 'ACTIVE');
        // Cache removal is repeatable; SQL transaction already marked worker offline.
        await redisClient.zRem(REDIS_WORKERS_GEO_KEY, actor);
        res.status(200).json({success:true, shift});
    } catch (error: any) { sendPublicError(res,error,'controller'); }
};

export const reconcileCash=async(req:Request,res:Response):Promise<void>=>{
    const actor=requireActor(req,res,'worker');if(!actor)return;
    if(!await requireOwnedShift(res,req.params.shiftId,actor,'worker'))return;
    res.status(409).json({success:false,error:'handshake_required',message:'Use the two-party cash acknowledgement flow'});
};

export const handleIvrCallback = async (req: Request, res: Response): Promise<void> => {
    try {
        const { shiftId } = req.params;
        const callerRole = res.locals.ivrRole;
        if (callerRole !== 'worker') {res.status(403).json({success:false,error:'Verified callback required'});return;}
        const digit = String(req.body.Digits ?? req.body.dtmfDigit ?? '').trim();

        if (!digit || (digit !== '1' && digit !== '2')) {
            if (req.body.Digits !== undefined) {
                res.setHeader('Content-Type', 'text/xml');
                res.status(200).send('<Response><Say voice="Polly.Aditi" language="en-IN">Invalid keypress. Please press 1 to confirm, or 2 to dispute.</Say></Response>');
                return;
            }
            res.status(400).json({
                success: false,
                error: 'Valid dtmfDigit (1 for confirm, 2 for dispute) is required'
            });
            return;
        }

        const targetShiftId = Array.isArray(shiftId) ? shiftId[0] : shiftId;
        const result = await processIvrKeypress(targetShiftId, callerRole, digit);

        // If called by Twilio Voice webhook, respond with compliant TwiML
        if (req.body.Digits !== undefined || req.headers['x-twilio-signature']) {
            res.setHeader('Content-Type', 'text/xml');
            const replyPrompt = digit === '1'
                ? 'Thank you. Your confirmation has been recorded successfully. Goodbye.'
                : 'Thank you. A payment dispute has been registered for this shift. Goodbye.';
            res.status(200).send(`<Response><Say voice="Polly.Aditi" language="en-IN">${replyPrompt}</Say></Response>`);
            return;
        }

        res.status(200).json(result);
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

export const getShiftById = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        if (!await requireOwnedShift(res, req.params.shiftId, actor, 'worker')) return;
        const { shiftId } = req.params;
        const result = await pool.query(
            `SELECT s.*, 
                    w.phone_number as worker_phone, w.worker_category, w.trust_score as worker_trust,
                    e.full_name as employer_name, e.phone_number as employer_phone
             FROM shifts s
             JOIN workers w ON s.worker_id = w.worker_id
             JOIN employers e ON s.employer_id = e.employer_id
             WHERE s.shift_id = $1 AND s.worker_id = $2`,
            [shiftId, actor]
        );

        if (result.rows.length === 0) {
            res.status(404).json({ success: false, error: 'Shift not found' });
            return;
        }

        res.status(200).json({ success: true, shift: result.rows[0] });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

export const getWorkerShifts = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        if (!requireOwnPath(res, req.params.userId, actor)) return;
        const { userId } = req.params;
        const result = await pool.query(
            'SELECT * FROM shifts WHERE worker_id = $1 ORDER BY created_at DESC',
            [userId]
        );
        res.status(200).json({ success: true, count: result.rows.length, shifts: result.rows });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 4. Ratings / Profile (from ratingController.ts)
export const getWorkerMyProfile = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        if (!requireOwnPath(res, req.params.workerId, actor)) return;
        const { workerId } = req.params;
        const targetWorkerId = Array.isArray(workerId) ? workerId[0] : workerId;


        const workerRes = await pool.query(
            `SELECT * FROM workers WHERE worker_id = $1`,
            [targetWorkerId]
        );

        if (workerRes.rows.length === 0) {
            res.status(404).json({ success: false, error: 'Worker not found' });
            return;
        }

        const worker = workerRes.rows[0];

        const reviewsRes = await pool.query(
            `SELECT r.rating_stars, r.review_comment, r.created_at, e.full_name as reviewer_name
             FROM ratings r
             JOIN employers e ON r.reviewer_id = e.employer_id
             WHERE r.reviewee_id = $1 AND r.reviewer_role = 'employer'
             ORDER BY r.created_at DESC`,
            [targetWorkerId]
        );

        const shiftsRes = await pool.query(
            `SELECT s.shift_id, s.status, s.agreed_daily_wage, s.adjusted_wage, 
                    s.actual_cash_paid, s.worked_hours, s.end_time as completed_at,
                    e.full_name as employer_name
             FROM shifts s
             JOIN employers e ON s.employer_id = e.employer_id
             WHERE s.worker_id = $1 AND s.status = 'COMPLETED'
             ORDER BY s.end_time DESC`,
            [targetWorkerId]
        );

        res.status(200).json({
            success: true,
            workerProfile: {
                workerId: worker.worker_id,
                phoneNumber: worker.phone_number,
                workerCategory: worker.worker_category,
                workerSubCategory: worker.worker_sub_category,
                isAvailable: worker.is_available,
                trustScore: Number(worker.trust_score),
                averageRating: Number(worker.average_rating),
                totalCompletedShifts: Number(worker.total_completed_shifts),
                totalRatingsCount: Number(worker.total_ratings_count),
                isVerifiedId: worker.is_verified_id,
                reviewsList: reviewsRes.rows.map((r: any) => ({
                    stars: r.rating_stars,
                    comment: r.review_comment,
                    reviewerName: r.reviewer_name,
                    date: r.created_at
                })),
                completedShiftsHistory: shiftsRes.rows.map((s: any) => ({
                    shiftId: s.shift_id,
                    employerName: s.employer_name,
                    wage: Number(s.adjusted_wage ?? s.agreed_daily_wage),
                    actualCashPaid: Number(s.actual_cash_paid),
                    workedHours: s.worked_hours ? Number(s.worked_hours) : 8,
                    completedAt: s.completed_at
                }))
            }
        });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

export const submitWorkerRating = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'worker');
        if (!actor) return;
        const { shiftId, ratingStars, reviewComment } = req.body;
        const owned = await requireOwnedShift(res, shiftId, actor, 'worker');
        if (!owned) return;
        const reviewerId = actor;
        const reviewerRole = 'worker';
        const revieweeId = owned.employer_id;

        if (!shiftId || !reviewerId || !revieweeId || !reviewerRole || ratingStars === undefined) {
            res.status(400).json({
                success: false,
                error: 'shiftId, reviewerId, revieweeId, reviewerRole ("worker"), and ratingStars (1-5) are required'
            });
            return;
        }

        if (reviewerRole !== 'worker') {
            res.status(400).json({ success: false, error: 'reviewerRole must be "worker" for this route' });
            return;
        }

        const stars = Math.min(5, Math.max(1, Number(ratingStars)));

        const insertResult = await pool.query(
            `INSERT INTO ratings (shift_id, reviewer_id, reviewee_id, reviewer_role, rating_stars, review_comment)
             SELECT $1, $2, $3, $4, $5, $6 FROM shifts
             WHERE shift_id = $1 AND worker_id = $2 AND employer_id = $3
             RETURNING *`,
            [shiftId, reviewerId, revieweeId, reviewerRole, stars, reviewComment ? reviewComment.trim() : null]
        );

        if (!insertResult.rows.length) { res.status(404).json({success:false, error:'Shift not found'}); return; }
        const rating = insertResult.rows[0];

        // Update Employer Rating
        const empAvgRes = await pool.query(
            `SELECT AVG(rating_stars) as avg_rating
             FROM ratings
             WHERE reviewee_id = $1 AND reviewer_role = 'worker'`,
            [revieweeId]
        );

        const newEmpRating = Math.round(Number(empAvgRes.rows[0].avg_rating || 5.0) * 100) / 100;
        await pool.query(
            `UPDATE employers SET trust_rating = $1 WHERE employer_id = $2`,
            [newEmpRating, revieweeId]
        );

        res.status(201).json({
            success: true,
            message: 'Rating and review submitted successfully.',
            rating
        });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 5. Worker Physical Cash Handshake Initiation
export const generateCashHandshakeCode=async(req:Request,res:Response):Promise<void>=>{
    try{const actor=requireActor(req,res,'worker');if(!actor)return;const result=await initiateCash(String(req.params.shiftId),actor,req.body);res.status(200).json(result);}
    catch(error:any){sendPublicError(res,error,'controller');}
};
