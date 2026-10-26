import { Request, Response } from 'express';
import pool from '../db/db.js';

export const requireActor = (req: Request, res: Response, role: 'worker' | 'employer'): string | null => {
    if (!req.user) { res.status(401).json({success: false, error: 'Authentication required'}); return null; }
    if (req.user.role !== role) { res.status(403).json({success: false, error: 'Forbidden'}); return null; }
    return req.user.userId;
};
export const requireOwnPath = (res: Response, pathId: unknown, actor: string): boolean => {
    if (pathId !== actor) { res.status(403).json({success: false, error: 'Forbidden'}); return false; }
    return true;
};
export const requireOwnedShift = async (res: Response, shiftId: unknown, actor: string, role: 'worker' | 'employer'): Promise<any | null> => {
    const column = role === 'worker' ? 'worker_id' : 'employer_id';
    const result = await pool.query(`SELECT * FROM shifts WHERE shift_id = $1 AND ${column} = $2`, [shiftId, actor]);
    if (!result.rows.length) { res.status(404).json({success: false, error: 'Shift not found'}); return null; }
    return result.rows[0];
};
