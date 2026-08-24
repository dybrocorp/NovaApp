/**
 * Shared fixture for the FASE 0.5 end-to-end validation suites.
 *
 * Every suite runs a REAL RealtimeServer over loopback WebSockets and
 * drives it with REAL NovaClient instances (server/src/client/nova_client.ts),
 * the same wire contract the Flutter app speaks.
 */
import { RealtimeServer, type RealtimeServerOptions } from '../src/realtime_server.js';
import { NovaClient, createIdentity, type NovaIdentity } from '../src/client/nova_client.js';

/** Captures redacted log lines so tests can assert no secret ever leaks. */
export class LogCapture {
  readonly lines: string[] = [];
  readonly sink = (line: string): void => {
    this.lines.push(line);
  };
  text(): string {
    return this.lines.join('\n');
  }
  clear(): void {
    this.lines.length = 0;
  }
}

export class World {
  server!: RealtimeServer;
  port!: number;
  readonly logs = new LogCapture();
  private readonly clients: NovaClient[] = [];
  private counter = 0;

  constructor(private readonly options: Omit<RealtimeServerOptions, 'logSink'> = {}) {}

  async start(): Promise<void> {
    this.server = new RealtimeServer({ ...this.options, logSink: this.logs.sink });
    this.port = await this.server.start({ host: '127.0.0.1' });
  }

  get url(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  /** Registers a brand-new identity (own account, own device, own key). */
  async seedIdentity(options: { accountId?: string; deviceId?: string; novaId?: string } = {}): Promise<NovaIdentity> {
    this.counter += 1;
    const identity = createIdentity({
      accountId: options.accountId ?? `acc-${this.counter}`,
      deviceId: options.deviceId ?? `dev-${this.counter}`,
      novaId: options.novaId,
    });
    await this.server.adminRegisterDevice({
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      novaId: identity.novaId,
      publicKeyBase64: identity.publicKeyBase64,
    });
    return identity;
  }

  /** Creates a client for an identity (not yet connected). */
  client(identity: NovaIdentity, name?: string): NovaClient {
    const client = new NovaClient({ url: this.url, identity, name });
    this.clients.push(client);
    return client;
  }

  /** Connects + authenticates in one step. */
  async connected(identity: NovaIdentity, name?: string): Promise<NovaClient> {
    const client = this.client(identity, name);
    client.connect();
    await client.authenticate();
    return client;
  }

  async conversation(conversationId: string, accountIds: string[]): Promise<void> {
    for (const accountId of accountIds) {
      await this.server.adminAddConversationMember(conversationId, accountId);
    }
  }

  async stop(): Promise<void> {
    for (const client of this.clients) client.disconnect();
    this.clients.length = 0;
    await this.server.stop();
  }
}

export const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));
