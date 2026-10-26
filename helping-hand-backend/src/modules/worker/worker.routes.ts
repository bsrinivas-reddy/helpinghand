import express, { Router } from 'express';
import { validateIvrCallback } from '../../middlewares/ivr.middleware.js';
import {
    registerWorker,
    toggleAvailability,
    updateLocation,
    getWorkerStatus,
    acceptShift,
    startShift,
    reconcileCash,
    generateCashHandshakeCode,
    handleIvrCallback,
    getShiftById,
    getWorkerShifts,
    getWorkerMyProfile,
    submitWorkerRating
} from './worker.controller.js';
import { authenticateToken, requireRole } from '../../middlewares/auth.middleware.js';
import { validateBody } from '../../middlewares/validate.middleware.js';
import {
    registerWorkerSchema,
    reconcileCashSchema,
    handshakeCodeSchema, workerCashSchema,
    submitRatingSchema
} from '../../utils/validation.schemas.js';

const router = Router();

// Public registration
router.post('/register', validateBody(registerWorkerSchema), registerWorker);

// Protected Worker Endpoints
router.post('/toggle-availability', authenticateToken, requireRole('worker'), toggleAvailability);
router.post('/location', authenticateToken, requireRole('worker'), updateLocation);
router.get('/status/:workerId', authenticateToken, requireRole('worker'), getWorkerStatus);
router.get('/profile/:workerId', authenticateToken, requireRole('worker'), getWorkerMyProfile);
router.get('/shifts/user/:userId', authenticateToken, requireRole('worker'), getWorkerShifts);
router.get('/shifts/:shiftId', authenticateToken, requireRole('worker'), getShiftById);
router.patch('/shifts/:shiftId/accept', authenticateToken, requireRole('worker'), acceptShift);
router.patch('/shifts/:shiftId/start', authenticateToken, requireRole('worker'), startShift);

// Cash Handshake (Worker initiates 4-digit code)
router.post(
    '/shifts/:shiftId/cash-handshake-code',
    authenticateToken,
    requireRole('worker'),
    validateBody(workerCashSchema),
    generateCashHandshakeCode
);

// Backward-compatible cash reconcile
router.post(
    '/shifts/:shiftId/reconcile-cash',
    authenticateToken,
    requireRole('worker'),
    reconcileCash
);

// IVR Telephony Callback (Webhook)
router.post('/shifts/:shiftId/ivr-callback', express.urlencoded({extended:false,limit:'16kb'}), validateIvrCallback('worker'), handleIvrCallback);

// Ratings
router.post(
    '/ratings/submit',
    authenticateToken,
    requireRole('worker'),
    validateBody(submitRatingSchema),
    submitWorkerRating
);

export default router;
