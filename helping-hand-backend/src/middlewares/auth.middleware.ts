import { Request, Response, NextFunction } from 'express';
import { verifyAccessToken, TokenPayload } from '../utils/jwt.js';

// Extend Express Request interface to include user
declare global {
    namespace Express {
        interface Request {
            user?: TokenPayload;
        }
    }
}

/**
 * Authenticate JWT Bearer token from Authorization header.
 * Requires a verified session in every environment.
 */
export const authenticateToken = (req: Request, res: Response, next: NextFunction): void => {
    const authHeader = req.headers.authorization;
    const token = authHeader && authHeader.startsWith('Bearer ') ? authHeader.split(' ')[1] : null;

    if (!token) {
        res.status(401).json({ success: false, error: 'Authentication required' });
        return;
    }

    try {
        const decoded = verifyAccessToken(token);
        req.user = decoded;
        next();
    } catch (err: any) {
        res.status(401).json({
            success: false,
            error: 'Invalid or expired access token'
        });
    }
};

/**
 * Role-Based Access Control (RBAC) middleware.
 * Ensures caller possesses one of the required roles.
 */
export const requireRole = (...allowedRoles: ('employer' | 'worker')[]) => {
    return (req: Request, res: Response, next: NextFunction): void => {
        if (!req.user) {
            res.status(401).json({ success: false, error: 'Authentication required' });
            return;
        }

        if (!allowedRoles.includes(req.user.role)) {
            res.status(403).json({
                success: false,
                error: `Forbidden: Access restricted to [${allowedRoles.join(', ')}]. Caller role: ${req.user.role}`
            });
            return;
        }

        next();
    };
};
