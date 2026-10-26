import pool from '../db/db.js';
export class FlowError extends Error {
    constructor(public status: number, message: string) {super(message);}
}
export const transaction = async <T>(work: (db: any) => Promise<T>): Promise<T> => {
    const db = await pool.connect();
    try { await db.query('BEGIN'); await db.query("SET LOCAL statement_timeout = '10s'"); const result = await work(db); await db.query('COMMIT'); return result; }
    catch (error) { await db.query('ROLLBACK'); throw error; }
    finally { db.release(); }
};
export const transitionWorkerShift = async (shiftId: string, workerId: string, target: 'ACCEPTED' | 'ACTIVE'): Promise<any> => transaction(async db => {
    // Serialize work assignment per worker before locking individual shifts.
    await db.query('SELECT worker_id FROM workers WHERE worker_id = $1 FOR UPDATE', [workerId]);
    const result = await db.query('SELECT * FROM shifts WHERE shift_id = $1 AND worker_id = $2 FOR UPDATE', [shiftId, workerId]);
    const shift = result.rows[0];
    if (!shift) throw new FlowError(404, 'Shift not found');
    if (shift.status === target) return shift;
    const expected = target === 'ACCEPTED' ? 'PENDING' : 'ACCEPTED';
    if (shift.status !== expected) throw new FlowError(409, 'Invalid shift transition');
    const busy = await db.query("SELECT shift_id FROM shifts WHERE worker_id = $1 AND shift_id <> $2 AND status IN ('ACCEPTED','ACTIVE')", [workerId, shiftId]);
    if (busy.rows.length) throw new FlowError(409, 'Worker already has an accepted or active shift');
    const updated = await db.query(`UPDATE shifts SET status = $1${target === 'ACTIVE' ? ', start_time = CURRENT_TIMESTAMP' : ''} WHERE shift_id = $2 AND worker_id = $3 AND status = $4 RETURNING *`, [target, shiftId, workerId, expected]);
    if (!updated.rows.length) throw new FlowError(409, 'Shift changed; refresh and retry');
    await db.query('UPDATE workers SET is_available = false WHERE worker_id = $1', [workerId]);
    return updated.rows[0];
});
export const createTargetedShift = async (employerId: string, workerId: string, wage: number): Promise<any> => transaction(async db => {
    if(!Number.isFinite(wage)||wage<=0)throw new FlowError(400,'Positive wage required');
    const worker = await db.query('SELECT worker_id, is_available FROM workers WHERE worker_id = $1 FOR UPDATE', [workerId]);
    if (!worker.rows.length) throw new FlowError(404, 'Worker not found');
    const existing = await db.query("SELECT * FROM shifts WHERE worker_id=$1 AND employer_id=$2 AND status='PENDING' ORDER BY created_at LIMIT 1",[workerId,employerId]);
    if(existing.rows.length) return existing.rows[0];
    if (!worker.rows[0].is_available) throw new FlowError(409, 'Worker is offline');
    const conflicts = await db.query("SELECT shift_id FROM shifts WHERE worker_id = $1 AND (status IN ('ACCEPTED','ACTIVE') OR (status = 'PENDING' AND employer_id = $2))", [workerId, employerId]);
    if (conflicts.rows.length) throw new FlowError(409, 'Worker is busy or request already exists');
    const employer = await db.query('SELECT employer_id FROM employers WHERE employer_id = $1', [employerId]);
    if (!employer.rows.length) throw new FlowError(404, 'Employer not found');
    const result = await db.query("INSERT INTO shifts (employer_id,worker_id,agreed_daily_wage,status,platform_fee_paid) VALUES ($1,$2,$3,'PENDING',false) RETURNING *", [employerId, workerId, wage]);
    return result.rows[0];
});
