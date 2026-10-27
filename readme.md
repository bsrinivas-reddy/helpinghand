# Helping Hand 🤝

A hyper-local daily labor marketplace connecting self-builders with verified informal laborers. This platform uses a dual-app architecture powered by a central Node.js/TypeScript backend, utilizing live GPS geofencing and real-time physical cash reconciliation.

## 🏗️ Repository Structure

This is a poly-folder monorepo. Each directory operates independently with its own configuration files.

| Folder | Tech Stack | Description |
| --- | --- | --- |
| `helping-hand-backend` | Node.js, Express, TypeScript | Core API, PostgreSQL ledger, and Redis geospatial matching engine. |
| `helping-hand-employer` | Flutter / Dart | Demand-side UI for booking labor, managing shifts, and checkout. |
| `helping-hand-worker-app` | Flutter / Dart | Supply-side UI optimized for single-tap operations and audio guidance. |

---

## 🛠️ Prerequisites

Before you start, ensure you have the following installed on your machine:

* **Git:** To clone the repository.
* **Node.js (v18+):** To run the Core API.
* **Docker Desktop:** To run the local PostgreSQL and Redis databases seamlessly.
* **Flutter SDK:** To run the mobile applications.

---

## 🚀 Step-by-Step Local Setup

Follow these exact steps to get the entire ecosystem running locally.

### 1. Clone the Repository

Open your terminal and clone the organization repository to your local machine.

```bash
git clone <YOUR_GITHUB_ORG_URL>/helping-hand.git
cd helping-hand

```

### 2. Configure Environment Variables

Navigate into the backend directory and create your environment file.

```bash
cd helping-hand-backend
touch .env

```

Paste the following baseline configuration into your new `.env` file:

```env
PORT=3000
DATABASE_URL=postgres://postgres:password123@localhost:5432/helping_hand
REDIS_URL=redis://localhost:6379

```

### 3. Spin Up the Databases (Docker)

Ensure Docker Desktop is running on your machine. We use Docker Compose to spin up isolated, perfectly versioned databases. This command will also automatically inject the `database_schema.sql` into PostgreSQL on its first boot.

```bash
# Ensure you are still inside helping-hand-backend
docker compose up -d

```

### 4. Install Backend Dependencies & Start Server

Install the Node modules and start the TypeScript development server using `tsx`.

```bash
npm install
npm run dev

```

Your server is now live. Verify the database connections by opening your browser and navigating to: `http://localhost:3000/health`.

### 5. Run the Mobile Apps

Open a new terminal window for each mobile application you want to run. Ensure you have an iOS Simulator or Android Emulator active.

**To start the Employer App:**

```bash
cd helping-hand/helping-hand-employer
flutter pub get
flutter run

```

**To start the Worker App:**

```bash
cd helping-hand/helping-hand-worker-app
flutter pub get
flutter run

```

---

### Release builds

- Backend: set `NODE_ENV=production` (the Dockerfile does), `CORS_ORIGINS` (explicit browser origins, or empty for none) and `TRUST_PROXY` (reverse-proxy hops, 0 if none). Dev shortcuts (mock Google token, OTP in the response, built-in JWT secrets, simulated SMS) work only when `NODE_ENV` is exactly `development` or `test`. Assumption: no deployed environment, staging included, runs with those two values; the code cannot tell a QA server from a laptop.
- Apps: build with `--dart-define=API_BASE_URL=https://your-api/api`. A release build refuses a missing or non-https URL.
- Android signing: put your upload keystore details in `android/key.properties` (gitignored: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`). Release builds stop without it and are never signed with the debug key.
- Cleartext http is enabled for debug builds only.

## 🛑 Important Development Rules

* **Do not delete `package-lock.json` or `tsconfig.json`:** These guarantee everyone is running the exact same environment and TypeScript compilation rules.
* **Strict Domain Isolation:** Do not cross-contaminate code. The Flutter apps must never connect directly to the databases; they must route all requests through the Express API in `helping-hand-backend`.
* **Database Updates:** If you need to add tables to the database, update the `database_schema.sql` file so the team stays synchronized, then rebuild your Docker container.