import express, { Router } from 'express';
import { validateIvrCallback } from '../../middlewares/ivr.middleware.js';
import {
    registerEmployer,
    findNearbyWorkers,
    createShift,
    adjustShiftTiming,
    reconcileCash,
    confirmCashHandshake,
    handleIvrCallback,
    getShiftById,
    getEmployerShifts,
    getWorkerMapSummary,
    submitEmployerRating
} from './employer.controller.js';
import { authenticateToken, requireRole } from '../../middlewares/auth.middleware.js';
import { validateBody } from '../../middlewares/validate.middleware.js';
import {
    registerEmployerSchema,
    createShiftSchema,
    reconcileCashSchema,
    confirmHandshakeSchema, employerCashSchema, adjustTimingSchema,
    submitRatingSchema
} from '../../utils/validation.schemas.js';

const router = Router();

// Public registration
router.post('/register', validateBody(registerEmployerSchema), registerEmployer);

// Protected Employer Endpoints
router.get('/nearby-workers', authenticateToken, requireRole('employer'), findNearbyWorkers);
router.get('/workers/:workerId/summary', authenticateToken, requireRole('employer'), getWorkerMapSummary);
router.post('/shifts/create', authenticateToken, requireRole('employer'), validateBody(createShiftSchema), createShift);
router.get('/shifts/user/:userId', authenticateToken, requireRole('employer'), getEmployerShifts);
router.get('/shifts/:shiftId', authenticateToken, requireRole('employer'), getShiftById);
router.patch('/shifts/:shiftId/adjust-timing', authenticateToken, requireRole('employer'), validateBody(adjustTimingSchema), adjustShiftTiming);

// Cash Handshake Confirmation (Employer verifies code + GPS)
router.post(
    '/shifts/:shiftId/confirm-cash-handshake',
    authenticateToken,
    requireRole('employer'),
    validateBody(employerCashSchema),
    confirmCashHandshake
);

// Backward-compatible cash reconcile
router.post(
    '/shifts/:shiftId/reconcile-cash',
    authenticateToken,
    requireRole('employer'),
    reconcileCash
);

// IVR Telephony Callback (Webhook)
router.post('/shifts/:shiftId/ivr-callback', express.urlencoded({extended:false,limit:'16kb'}), validateIvrCallback('employer'), handleIvrCallback);

// Ratings
router.post(
    '/ratings/submit',
    authenticateToken,
    requireRole('employer'),
    validateBody(submitRatingSchema),
    submitEmployerRating
);

export default router;
