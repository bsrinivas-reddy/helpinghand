import {sendPublicError,reportInternal} from '../../utils/publicError.js';
import { initiateCash, completeCash } from '../../services/cashHandshake.service.js';
import { createTargetedShift, FlowError, transaction } from '../../services/shiftState.service.js';
import { consumeRegistrationGrant } from '../../utils/registrationGrant.js';
import { requireActor, requireOwnPath, requireOwnedShift } from '../../utils/ownership.js';
import { Request, Response } from 'express';
import pool from '../../db/db.js';
import redisClient from '../../db/redisClient.js';
import { REDIS_WORKERS_GEO_KEY } from '../../utils/constants.js';
import { calculateHaversineDistance } from '../../utils/haversine.js';
import { processIvrKeypress } from '../../services/ivrService.js';
import { signAccessToken, signRefreshToken } from '../../utils/jwt.js';
import { MatchedWorker } from '../../types/index.js';

// 1. Employer Registration (from authController.ts)
export const registerEmployer = async (req: Request, res: Response): Promise<void> => {
    try {
        const { phoneNumber, fullName, upiId } = req.body;
        if (!phoneNumber || !fullName) {
            res.status(400).json({
                success: false,
                error: 'phoneNumber and fullName are required'
            });
            return;
        }

        const cleanedPhone = phoneNumber.trim();
        if (!await consumeRegistrationGrant(req.body.registrationGrant, cleanedPhone, 'employer')) {
            res.status(401).json({success:false, error:'Valid registration grant required'}); return;
        }
        const existing = await pool.query('SELECT 1 FROM employers WHERE phone_number = $1', [cleanedPhone]);
        if (existing.rows.length) { res.status(409).json({success:false, error:'Account already exists; sign in'}); return; }


        const result = await pool.query(
            `INSERT INTO employers (phone_number, full_name, upi_id)
             VALUES ($1, $2, $3)
             RETURNING *`,
            [cleanedPhone, fullName.trim(), upiId ? upiId.trim() : null]
        );

        const user = result.rows[0];
        const token = signAccessToken({
            userId: user.employer_id,
            role: 'employer',
            phoneNumber: cleanedPhone,
            email: user.email
        });
        const refreshToken = signRefreshToken({
            userId: user.employer_id,
            role: 'employer',
            phoneNumber: cleanedPhone,
            email: user.email
        });

        res.status(201).json({
            success: true,
            role: 'employer',
            token,
            refreshToken,
            user
        });
    } catch (error: any) {
        if (error.code === '23505') { res.status(409).json({success:false, error:'Account already exists; sign in'}); return; }
        sendPublicError(res,error,'controller');
    }
};

// 2. Worker Discovery (from demandController.ts)
export const findNearbyWorkers = async (req: Request, res: Response): Promise<void> => {
    try {
        const lat = req.query.lat ? Number(req.query.lat) : undefined;
        const lng = req.query.lng ? Number(req.query.lng) : undefined;
        const radiusKm = req.query.radiusKm ? Number(req.query.radiusKm) : 5;
        const category = req.query.category ? String(req.query.category).trim() : undefined;

        if (lat === undefined || lng === undefined || isNaN(lat) || isNaN(lng)) {
            res.status(400).json({
                success: false,
                error: 'Valid lat and lng query parameters are required'
            });
            return;
        }

        let workerIds: string[] = [];

        try {
            const redisMembers = await redisClient.geoSearch(
                REDIS_WORKERS_GEO_KEY,
                { latitude: lat, longitude: lng },
                { radius: radiusKm, unit: 'km' }
            );
            workerIds = redisMembers as string[];
        } catch (redisErr) {
            reportInternal('discovery_cache_fallback');
        }

        let query = `
            SELECT worker_id, phone_number, worker_category, worker_sub_category, trust_score, 
                   is_available, last_known_lat, last_known_lng
            FROM workers
            WHERE is_available = true
              AND NOT EXISTS (SELECT 1 FROM shifts occupied WHERE occupied.worker_id = workers.worker_id AND occupied.status IN ('ACCEPTED','ACTIVE'))
        `;
        const queryParams: any[] = [];

        if (workerIds.length > 0) {
            query += ` AND worker_id = ANY($1)`;
            queryParams.push(workerIds);
            if (category) {
                query += ` AND UPPER(worker_category) = UPPER($2)`;
                queryParams.push(category);
            }
        } else {
            if (category) {
                query += ` AND UPPER(worker_category) = UPPER($1)`;
                queryParams.push(category);
            }
        }

        const pgResult = await pool.query(query, queryParams);

        const matchedWorkers: MatchedWorker[] = [];

        for (const row of pgResult.rows) {
            const wLat = Number(row.last_known_lat);
            const wLng = Number(row.last_known_lng);
            if (isNaN(wLat) || isNaN(wLng)) continue;

            const distanceMeters = Math.round(calculateHaversineDistance(lat, lng, wLat, wLng));
            if (distanceMeters > radiusKm * 1000) continue;

            matchedWorkers.push({
                workerId: row.worker_id,
                phoneNumber: row.phone_number,
                workerCategory: row.worker_category,
                workerSubCategory: row.worker_sub_category || undefined,
                trustScore: Number(row.trust_score),
                lat: wLat,
                lng: wLng,
                distanceMeters
            });
        }

        matchedWorkers.sort((a, b) => a.distanceMeters - b.distanceMeters);

        res.status(200).json({
            success: true,
            employerLocation: { lat, lng },
            searchRadiusKm: radiusKm,
            count: matchedWorkers.length,
            workers: matchedWorkers
        });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 3. Shift Management (from shiftController.ts)
export const createShift = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'employer'); if (!actor) return;
        const {workerId, agreedDailyWage} = req.body;
        if (!workerId || !Number.isFinite(agreedDailyWage) || agreedDailyWage <= 0) {res.status(400).json({success:false,error:'Worker and positive wage required'});return;}
        const shift = await createTargetedShift(actor, workerId, agreedDailyWage);
        res.status(201).json({success:true,shift});
    } catch (error: any) {sendPublicError(res,error,'controller');}
};

export const adjustShiftTiming=async(req:Request,res:Response):Promise<void>=>{
    try{
        const actor=requireActor(req,res,'employer');if(!actor)return;
        const shift=await transaction(async db=>{
            const found=await db.query('SELECT * FROM shifts WHERE shift_id=$1 AND employer_id = $2 FOR UPDATE',[req.params.shiftId,actor]);const row=found.rows[0];
            if(!row)throw new FlowError(404,'Shift not found');if(row.status==='COMPLETED'||row.status==='CANCELLED')throw new FlowError(409,'Terminal wage is immutable');
            const {startTime,endTime,workedHours,customWage,reason,standardHoursPerDay}=req.body;
            const standard=standardHoursPerDay??8;
            const start=startTime?new Date(startTime):row.start_time?new Date(row.start_time):null;
            const end=endTime?new Date(endTime):row.end_time?new Date(row.end_time):null;
            if(start&&end&&end<=start)throw new FlowError(400,'End must follow start');
            const hours=workedHours??(start&&end?(end.getTime()-start.getTime())/3600000:Number(row.worked_hours??standard));
            const wage=customWage??Math.round(hours/standard*Number(row.agreed_daily_wage)*100)/100;
            if(!Number.isFinite(hours)||hours<=0||!Number.isFinite(wage)||wage<=0)throw new FlowError(400,'Positive valid hours and wage required');
            const result=await db.query("UPDATE shifts SET start_time=$1,end_time=$2,worked_hours=$3,adjusted_wage=$4,adjustment_reason=$5 WHERE shift_id=$6 AND employer_id=$7 AND status NOT IN ('COMPLETED','CANCELLED') RETURNING *",[start,end,hours,wage,reason??'Shift timing adjusted',req.params.shiftId,actor]);
            if(!result.rows.length)throw new FlowError(409,'Shift changed');return result.rows[0];
        });res.status(200).json({success:true,shift});
    }catch(error:any){sendPublicError(res,error,'controller');}
};

export const reconcileCash=async(req:Request,res:Response):Promise<void>=>{
    const actor=requireActor(req,res,'employer');if(!actor)return;
    if(!await requireOwnedShift(res,req.params.shiftId,actor,'employer'))return;
    res.status(409).json({success:false,error:'handshake_required',message:'Use the two-party cash acknowledgement flow'});
};

export const handleIvrCallback = async (req: Request, res: Response): Promise<void> => {
    try {
        const { shiftId } = req.params;
        const callerRole = res.locals.ivrRole;
        if (callerRole !== 'employer') {res.status(403).json({success:false,error:'Verified callback required'});return;}
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
        const actor = requireActor(req, res, 'employer');
        if (!actor) return;
        if (!await requireOwnedShift(res, req.params.shiftId, actor, 'employer')) return;
        const { shiftId } = req.params;
        const result = await pool.query(
            `SELECT s.*, 
                    w.phone_number as worker_phone, w.worker_category, w.trust_score as worker_trust,
                    e.full_name as employer_name, e.phone_number as employer_phone
             FROM shifts s
             JOIN workers w ON s.worker_id = w.worker_id
             JOIN employers e ON s.employer_id = e.employer_id
             WHERE s.shift_id = $1 AND s.employer_id = $2`,
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

export const getEmployerShifts = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'employer');
        if (!actor) return;
        if (!requireOwnPath(res, req.params.userId, actor)) return;
        const { userId } = req.params;
        const result = await pool.query(
            'SELECT * FROM shifts WHERE employer_id = $1 ORDER BY created_at DESC',
            [userId]
        );
        res.status(200).json({ success: true, count: result.rows.length, shifts: result.rows });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

// 4. Worker Info & Rating (from ratingController.ts)
export const getWorkerMapSummary = async (req: Request, res: Response): Promise<void> => {
    try {
        const { workerId } = req.params;
        const targetWorkerId = Array.isArray(workerId) ? workerId[0] : workerId;

        const workerRes = await pool.query(
            `SELECT worker_id, phone_number, worker_category, worker_sub_category, 
                    is_available, trust_score, average_rating, total_completed_shifts, 
                    total_ratings_count, is_verified_id, last_known_lat, last_known_lng
             FROM workers
             WHERE worker_id = $1`,
            [targetWorkerId]
        );

        if (workerRes.rows.length === 0) {
            res.status(404).json({ success: false, error: 'Worker not found' });
            return;
        }

        const worker = workerRes.rows[0];

        const reviewsRes = await pool.query(
            `SELECT rating_stars, review_comment, created_at
             FROM ratings
             WHERE reviewee_id = $1 AND reviewer_role = 'employer' AND review_comment IS NOT NULL
             ORDER BY created_at DESC
             LIMIT 2`,
            [targetWorkerId]
        );

        res.status(200).json({
            success: true,
            mapSummaryCard: {
                workerId: worker.worker_id,
                workerCategory: worker.worker_category,
                workerSubCategory: worker.worker_sub_category,
                trustScore: Number(worker.trust_score),
                averageRating: Number(worker.average_rating),
                totalCompletedShifts: Number(worker.total_completed_shifts),
                totalRatingsCount: Number(worker.total_ratings_count),
                isVerifiedId: worker.is_verified_id,
                recentReviews: reviewsRes.rows.map((r: any) => ({
                    stars: r.rating_stars,
                    comment: r.review_comment,
                    date: r.created_at
                }))
            }
        });
    } catch (error: any) {
        sendPublicError(res,error,'controller');
    }
};

export const submitEmployerRating = async (req: Request, res: Response): Promise<void> => {
    try {
        const actor = requireActor(req, res, 'employer');
        if (!actor) return;
        const { shiftId, ratingStars, reviewComment } = req.body;
        const owned = await requireOwnedShift(res, shiftId, actor, 'employer');
        if (!owned) return;
        const reviewerId = actor;
        const reviewerRole = 'employer';
        const revieweeId = owned.worker_id;

        if (!shiftId || !reviewerId || !revieweeId || !reviewerRole || ratingStars === undefined) {
            res.status(400).json({
                success: false,
                error: 'shiftId, reviewerId, revieweeId, reviewerRole ("employer"), and ratingStars (1-5) are required'
            });
            return;
        }

        if (reviewerRole !== 'employer') {
            res.status(400).json({ success: false, error: 'reviewerRole must be "employer" for this route' });
            return;
        }

        const stars = Math.min(5, Math.max(1, Number(ratingStars)));

        const insertResult = await pool.query(
            `INSERT INTO ratings (shift_id, reviewer_id, reviewee_id, reviewer_role, rating_stars, review_comment)
             SELECT $1, $2, $3, $4, $5, $6 FROM shifts
             WHERE shift_id = $1 AND employer_id = $2 AND worker_id = $3
             RETURNING *`,
            [shiftId, reviewerId, revieweeId, reviewerRole, stars, reviewComment ? reviewComment.trim() : null]
        );

        if (!insertResult.rows.length) { res.status(404).json({success:false, error:'Shift not found'}); return; }
        const rating = insertResult.rows[0];

        // Update Worker Reputation & Total Completed Shifts Count
        const avgRes = await pool.query(
            `SELECT AVG(rating_stars) as avg_rating, COUNT(rating_id) as total_ratings
             FROM ratings
             WHERE reviewee_id = $1 AND reviewer_role = 'employer'`,
            [revieweeId]
        );

        const newAvgRating = Math.round(Number(avgRes.rows[0].avg_rating || 5.0) * 100) / 100;
        const totalRatings = Number(avgRes.rows[0].total_ratings || 0);

        const completedShiftsRes = await pool.query(
            `SELECT COUNT(shift_id) as completed_count
             FROM shifts
             WHERE worker_id = $1 AND status = 'COMPLETED'`,
            [revieweeId]
        );
        const totalCompleted = Number(completedShiftsRes.rows[0].completed_count || 0);

        await pool.query(
            `UPDATE workers 
             SET average_rating = $1, trust_score = $1, total_ratings_count = $2, total_completed_shifts = $3
             WHERE worker_id = $4`,
            [newAvgRating, totalRatings, totalCompleted, revieweeId]
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

// 5. Employer Physical Cash Handshake Confirmation (with GPS Verification)
export const confirmCashHandshake=async(req:Request,res:Response):Promise<void>=>{
    try{const actor=requireActor(req,res,'employer');if(!actor)return;const result=await completeCash(String(req.params.shiftId),actor,req.body);res.status(200).json(result);}
    catch(error:any){sendPublicError(res,error,'controller');}
};
