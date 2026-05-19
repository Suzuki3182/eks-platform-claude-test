import express, { Request, Response } from 'express';

const app = express();
const port = parseInt(process.env.PORT ?? '3000', 10);

app.use(express.json());

app.get('/health', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.get('/', (_req: Request, res: Response) => {
  res.json({
    message: 'TypeScript application running on EKS',
    version: process.env.APP_VERSION ?? 'unknown',
    environment: process.env.NODE_ENV ?? 'development',
  });
});

app.listen(port, () => {
  console.log(`Server listening on port ${port}`);
});
