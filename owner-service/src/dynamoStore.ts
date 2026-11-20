import { DynamoDBClient, ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand, QueryCommand, UpdateCommand,
  BatchWriteCommand, TransactWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import type {
  Store, UserRecord, LoginCodeRecord, SessionRecord, ConnectionRecord, ConnectionPatch, AccountSecurity, AuthChallenge,
  InviteRecord,
} from './store.ts';

/**
 * Single-table DynamoDB store.
 *
 *   pk                 sk                gsi1pk          gsi1sk          item
 *   USER#<id>          PROFILE                                           user profile
 *   USER#<id>          CONN#<id>         ITEM#<itemId>   USER#<id>       bank connection
 *   USER#<id>          CRID#<id>                                         idempotency claim
 *   EMAIL#<key>        USER                                              email → user ID (unique)
 *   EMAIL#<key>        CODE                                              one-time sign-in code (TTL)
 *   EMAIL#<key>        INVITE                                            unredeemed sign-up invite (TTL)
 *   SESSION#<id>       SESSION           USER#<id>       SESSION#<id>    refresh-token session (TTL)
 *   AUTH#<id>          CHALLENGE         USER#<id>       AUTH#<id>       factor challenge (TTL)
 *
 * The table has TTL on `ttl` (epoch seconds), on-demand capacity and AWS-managed encryption at rest.
 * Plaid access tokens are additionally sealed with KMS before they reach this layer.
 */
export class DynamoStore implements Store {
  private readonly db: DynamoDBDocumentClient;
  private readonly table: string;

  constructor(table: string, region: string) {
    this.table = table;
    this.db = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
      marshallOptions: { removeUndefinedValues: true },
    });
  }

  private async get(pk: string, sk: string): Promise<Record<string, unknown> | null> {
    const r = await this.db.send(new GetCommand({ TableName: this.table, Key: { pk, sk }, ConsistentRead: true }));
    return (r.Item as Record<string, unknown>) ?? null;
  }

  private async queryAll(input: { index?: string; key: string; value: string; skPrefix?: string }) {
    const items: Record<string, unknown>[] = [];
    let start: Record<string, unknown> | undefined;
    const pkName = input.index ? 'gsi1pk' : 'pk';
    const skName = input.index ? 'gsi1sk' : 'sk';
    do {
      const r = await this.db.send(new QueryCommand({
        TableName: this.table,
        IndexName: input.index,
        KeyConditionExpression: input.skPrefix ? '#p = :p AND begins_with(#s, :s)' : '#p = :p',
        ExpressionAttributeNames: input.skPrefix ? { '#p': pkName, '#s': skName } : { '#p': pkName },
        ExpressionAttributeValues: input.skPrefix ? { ':p': input.value, ':s': input.skPrefix } : { ':p': input.value },
        ExclusiveStartKey: start,
      }));
      items.push(...((r.Items as Record<string, unknown>[]) ?? []));
      start = r.LastEvaluatedKey as Record<string, unknown> | undefined;
    } while (start);
    return items;
  }

  // --- Users -------------------------------------------------------------------

  async findUserIdByEmailKey(emailKey: string) {
    const item = await this.get(`EMAIL#${emailKey}`, 'USER');
    return (item?.userId as string) ?? null;
  }

  async createUser(emailKey: string, email: string): Promise<UserRecord> {
    const user: UserRecord = { id: crypto.randomUUID(), email, createdAt: new Date().toISOString() };
    try {
      await this.db.send(new TransactWriteCommand({
        TransactItems: [
          { Put: { TableName: this.table, Item: { pk: `EMAIL#${emailKey}`, sk: 'USER', userId: user.id },
                   ConditionExpression: 'attribute_not_exists(pk)' } },
          { Put: { TableName: this.table, Item: { pk: `USER#${user.id}`, sk: 'PROFILE', ...user } } },
        ],
      }));
      return user;
    } catch (e) {
      if ((e as Error).name !== 'TransactionCanceledException') throw e;
      const existing = await this.findUserIdByEmailKey(emailKey);
      const record = existing ? await this.getUser(existing) : null;
      if (!record) throw e;
      return record;
    }
  }

  async createInvitedUser(emailKey: string, email: string, now: number): Promise<UserRecord | null> {
    const existingId = await this.findUserIdByEmailKey(emailKey);
    if (existingId) return this.getUser(existingId);
    const user: UserRecord = { id: crypto.randomUUID(), email, createdAt: new Date(now).toISOString() };
    try {
      await this.db.send(new TransactWriteCommand({
        TransactItems: [
          // TTL deletion lags by up to days, so the expiry is checked here as well.
          { Delete: { TableName: this.table, Key: { pk: `EMAIL#${emailKey}`, sk: 'INVITE' },
                      ConditionExpression: 'attribute_exists(pk) AND expiresAt > :now',
                      ExpressionAttributeValues: { ':now': now } } },
          { Put: { TableName: this.table, Item: { pk: `EMAIL#${emailKey}`, sk: 'USER', userId: user.id },
                   ConditionExpression: 'attribute_not_exists(pk)' } },
          { Put: { TableName: this.table, Item: { pk: `USER#${user.id}`, sk: 'PROFILE', ...user } } },
        ],
      }));
      return user;
    } catch (e) {
      if ((e as Error).name !== 'TransactionCanceledException') throw e;
      // Another request may have created the account first; that one consumed the invite.
      const winner = await this.findUserIdByEmailKey(emailKey);
      if (winner) return this.getUser(winner);
      const reasons = (e as { CancellationReasons?: { Code?: string }[] }).CancellationReasons;
      if (reasons?.[0]?.Code === 'ConditionalCheckFailed') return null;
      throw e;
    }
  }

  async getUser(userId: string) {
    const item = await this.get(`USER#${userId}`, 'PROFILE');
    return item ? { id: item.id as string, email: item.email as string, createdAt: item.createdAt as string,
                    security: item.security as AccountSecurity | undefined } : null;
  }

  async saveSecurity(userId: string, expectedRevision: number, security: AccountSecurity) {
    try {
      await this.db.send(new UpdateCommand({
        TableName: this.table, Key: { pk: `USER#${userId}`, sk: 'PROFILE' },
        UpdateExpression: 'SET #security = :new',
        ConditionExpression: expectedRevision === 0 ? 'attribute_exists(pk) AND attribute_not_exists(#security)'
          : 'attribute_exists(pk) AND #security.#revision = :old',
        ExpressionAttributeNames: expectedRevision === 0 ? { '#security': 'security' }
          : { '#security': 'security', '#revision': 'revision' },
        ExpressionAttributeValues: expectedRevision === 0 ? { ':new': security } : { ':new': security, ':old': expectedRevision },
      }));
      return true;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return false;
      throw e;
    }
  }

  async deleteUser(userId: string, emailKey: string) {
    const owned = await this.queryAll({ key: 'pk', value: `USER#${userId}` });
    const authRecords = await this.queryAll({ index: 'gsi1', key: 'gsi1pk', value: `USER#${userId}` });
    // Delete email mappings, invites, connections and secondary records before PROFILE and SESSION records
    // so a retry after transient throttling can still authenticate and finish erasing everything.
    const profileKeys = owned.filter((i) => i.sk === 'PROFILE').map((i) => ({ pk: i.pk, sk: i.sk }));
    const otherOwnedKeys = owned.filter((i) => i.sk !== 'PROFILE').map((i) => ({ pk: i.pk, sk: i.sk }));
    const sessionKeys = authRecords.filter((i) => i.sk === 'SESSION').map((i) => ({ pk: i.pk, sk: i.sk }));
    const otherAuthKeys = authRecords.filter((i) => i.sk !== 'SESSION').map((i) => ({ pk: i.pk, sk: i.sk }));
    const keys = [
      { pk: `EMAIL#${emailKey}`, sk: 'USER' },
      { pk: `EMAIL#${emailKey}`, sk: 'CODE' },
      { pk: `EMAIL#${emailKey}`, sk: 'INVITE' },
      ...otherOwnedKeys,
      ...otherAuthKeys,
      ...sessionKeys,
      ...profileKeys,
    ];
    for (let i = 0; i < keys.length; i += 25) {
      let request: Record<string, any[]> | undefined = {
        [this.table]: keys.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } })),
      };
      for (let attempt = 0; request && Object.keys(request).length && attempt < 5; attempt++) {
        const r = await this.db.send(new BatchWriteCommand({ RequestItems: request }));
        request = r.UnprocessedItems as Record<string, any[]> | undefined;
        if (request && Object.keys(request).length) await new Promise((res) => setTimeout(res, 100 * 2 ** attempt));
      }
      if (request && Object.keys(request).length) {
        throw new Error('Account deletion did not complete: unprocessed DynamoDB items remain');
      }
    }
  }

  // --- Invites -------------------------------------------------------------------

  async putInvite(invite: InviteRecord) {
    await this.db.send(new PutCommand({
      TableName: this.table,
      Item: { pk: `EMAIL#${invite.emailKey}`, sk: 'INVITE', ...invite, ttl: Math.ceil(invite.expiresAt / 1000) },
    }));
  }

  async getInvite(emailKey: string) {
    const item = await this.get(`EMAIL#${emailKey}`, 'INVITE');
    return item ? { emailKey, createdAt: item.createdAt as string, expiresAt: item.expiresAt as number } : null;
  }

  async deleteInvite(emailKey: string) {
    await this.db.send(new DeleteCommand({ TableName: this.table, Key: { pk: `EMAIL#${emailKey}`, sk: 'INVITE' } }));
  }

  // --- Sign-in codes -------------------------------------------------------------

  async getLoginCode(emailKey: string) {
    const item = await this.get(`EMAIL#${emailKey}`, 'CODE');
    if (!item) return null;
    return {
      emailKey, codeHash: item.codeHash as string, expiresAt: item.expiresAt as number, attempts: item.attempts as number,
      windowStart: item.windowStart as number, sentInWindow: item.sentInWindow as number,
    };
  }

  async putLoginCode(record: LoginCodeRecord, expected: LoginCodeRecord | null) {
    const ttl = Math.ceil(Math.max(record.expiresAt, record.windowStart + 3_600_000) / 1000);
    try {
      await this.db.send(new PutCommand({
        TableName: this.table, Item: { pk: `EMAIL#${record.emailKey}`, sk: 'CODE', ...record, ttl },
        ConditionExpression: expected
          ? 'codeHash = :hash AND attempts = :attempts AND windowStart = :window AND sentInWindow = :sent'
          : 'attribute_not_exists(pk)',
        ExpressionAttributeValues: expected
          ? { ':hash': expected.codeHash, ':attempts': expected.attempts, ':window': expected.windowStart, ':sent': expected.sentInWindow }
          : undefined,
      }));
      return true;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return false;
      throw e;
    }
  }

  async putAuthChallenge(challenge: AuthChallenge) {
    const pk = `AUTH#${challenge.id}`;
    const owner = challenge.userId ? { gsi1pk: `USER#${challenge.userId}`, gsi1sk: pk } : {};
    await this.db.send(new PutCommand({
      TableName: this.table, Item: { pk, sk: 'CHALLENGE', ...owner, ...challenge, ttl: Math.ceil(challenge.expiresAt / 1000) },
      ConditionExpression: 'attribute_not_exists(pk)',
    }));
  }

  private challengeCondition(kind: AuthChallenge['kind'], now: number, sessionId?: string) {
    return {
      condition: `#kind = :kind AND expiresAt > :now AND ${sessionId ? 'sessionId = :session' : 'attribute_not_exists(sessionId)'}`,
      values: { ':kind': kind, ':now': now, ...(sessionId ? { ':session': sessionId } : {}) },
    };
  }

  async attemptAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string) {
    const { condition, values } = this.challengeCondition(kind, now, sessionId);
    try {
      const r = await this.db.send(new UpdateCommand({
        TableName: this.table, Key: { pk: `AUTH#${id}`, sk: 'CHALLENGE' },
        UpdateExpression: 'SET #attempts = #attempts + :one',
        ConditionExpression: `${condition} AND #attempts < :max`,
        ExpressionAttributeNames: { '#kind': 'kind', '#attempts': 'attempts' },
        ExpressionAttributeValues: { ...values, ':one': 1, ':max': 5 }, ReturnValues: 'ALL_NEW',
      }));
      return r.Attributes as AuthChallenge;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return null;
      throw e;
    }
  }

  async takeAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string) {
    const { condition, values } = this.challengeCondition(kind, now, sessionId);
    try {
      const r = await this.db.send(new DeleteCommand({
        TableName: this.table, Key: { pk: `AUTH#${id}`, sk: 'CHALLENGE' },
        ExpressionAttributeNames: { '#kind': 'kind' },
        ConditionExpression: condition, ExpressionAttributeValues: values, ReturnValues: 'ALL_OLD',
      }));
      return r.Attributes as AuthChallenge;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return null;
      throw e;
    }
  }

  // --- Sessions --------------------------------------------------------------------

  async putSession(s: SessionRecord) {
    await this.db.send(new PutCommand({
      TableName: this.table,
      Item: { pk: `SESSION#${s.id}`, sk: 'SESSION', gsi1pk: `USER#${s.userId}`, gsi1sk: `SESSION#${s.id}`, ...s,
              ttl: Math.ceil(s.expiresAt / 1000) },
    }));
  }

  async getSession(sessionId: string) {
    const i = await this.get(`SESSION#${sessionId}`, 'SESSION');
    if (!i) return null;
    return {
      id: i.id as string, userId: i.userId as string, tokenHash: i.tokenHash as string,
      prevTokenHash: i.prevTokenHash as string | undefined,
      createdAt: i.createdAt as string, expiresAt: i.expiresAt as number,
      securityEpoch: i.securityEpoch as number | undefined,
    };
  }

  async rotateSession(sessionId: string, expectedHash: string, newHash: string, expiresAt: number) {
    try {
      await this.db.send(new UpdateCommand({
        TableName: this.table, Key: { pk: `SESSION#${sessionId}`, sk: 'SESSION' },
        UpdateExpression: 'SET tokenHash = :new, prevTokenHash = :old, expiresAt = :exp, #ttl = :ttl REMOVE deviceName, lastUsedAt',
        ConditionExpression: 'tokenHash = :old',
        ExpressionAttributeNames: { '#ttl': 'ttl' },
        ExpressionAttributeValues: {
          ':new': newHash, ':old': expectedHash, ':exp': expiresAt,
          ':ttl': Math.ceil(expiresAt / 1000),
        },
      }));
      return true;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return false;
      throw e;
    }
  }

  async deleteSession(sessionId: string) {
    await this.db.send(new DeleteCommand({ TableName: this.table, Key: { pk: `SESSION#${sessionId}`, sk: 'SESSION' } }));
  }

  // --- Connections -----------------------------------------------------------------

  async claimClientRequest(userId: string, clientRequestId: string, connectionId: string) {
    const ttl = Math.ceil((Date.now() + 24 * 3600_000) / 1000);
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        await this.db.send(new PutCommand({
          TableName: this.table,
          Item: { pk: `USER#${userId}`, sk: `CRID#${clientRequestId}`, connectionId, ttl },
          ConditionExpression: 'attribute_not_exists(pk)',
        }));
        return connectionId;
      } catch (e) {
        if (!(e instanceof ConditionalCheckFailedException)) throw e;
        const existing = await this.get(`USER#${userId}`, `CRID#${clientRequestId}`);
        if (existing) return existing.connectionId as string;
      }
    }
    throw new Error('Could not claim clientRequestId after concurrent release');
  }

  async releaseClientRequest(userId: string, clientRequestId: string, connectionId: string) {
    try {
      await this.db.send(new DeleteCommand({
        TableName: this.table,
        Key: { pk: `USER#${userId}`, sk: `CRID#${clientRequestId}` },
        ConditionExpression: 'connectionId = :cid',
        ExpressionAttributeValues: { ':cid': connectionId },
      }));
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return;
      throw e;
    }
  }

  private static toConnection(i: Record<string, unknown>): ConnectionRecord {
    const { pk: _pk, sk: _sk, gsi1pk: _g1, gsi1sk: _g2, ...rest } = i;
    return rest as unknown as ConnectionRecord;
  }

  async putConnection(c: ConnectionRecord) {
    await this.db.send(new PutCommand({
      TableName: this.table,
      Item: { pk: `USER#${c.userId}`, sk: `CONN#${c.id}`, gsi1pk: `ITEM#${c.itemId}`, gsi1sk: `USER#${c.userId}`, ...c },
    }));
  }

  async getConnection(userId: string, connectionId: string) {
    const i = await this.get(`USER#${userId}`, `CONN#${connectionId}`);
    return i ? DynamoStore.toConnection(i) : null;
  }

  async listConnections(userId: string) {
    const items = await this.queryAll({ key: 'pk', value: `USER#${userId}`, skPrefix: 'CONN#' });
    return items.map(DynamoStore.toConnection).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async updateConnection(userId: string, connectionId: string, patch: ConnectionPatch) {
    const sets: string[] = [];
    const removes: string[] = [];
    const names: Record<string, string> = {};
    const values: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(patch)) {
      if (v === undefined) continue;
      names[`#${k}`] = k;
      if (v === null && (k === 'sealedAccessToken' || k === 'billConsent' || k === 'pendingBillConsent')) removes.push(`#${k}`);
      else { sets.push(`#${k} = :${k}`); values[`:${k}`] = v; }
    }
    if (!sets.length && !removes.length) return this.getConnection(userId, connectionId);
    const expression = [sets.length ? `SET ${sets.join(', ')}` : '', removes.length ? `REMOVE ${removes.join(', ')}` : '']
      .filter(Boolean).join(' ');
    try {
      const r = await this.db.send(new UpdateCommand({
        TableName: this.table, Key: { pk: `USER#${userId}`, sk: `CONN#${connectionId}` },
        UpdateExpression: expression,
        ConditionExpression: 'attribute_exists(pk)',
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: Object.keys(values).length ? values : undefined,
        ReturnValues: 'ALL_NEW',
      }));
      return r.Attributes ? DynamoStore.toConnection(r.Attributes as Record<string, unknown>) : null;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return null;
      throw e;
    }
  }

  async confirmBillConsent(userId: string, connectionId: string, id: string, now: number) {
    try {
      await this.db.send(new UpdateCommand({
        TableName: this.table, Key: { pk: `USER#${userId}`, sk: `CONN#${connectionId}` },
        UpdateExpression: 'SET #consent = :granted REMOVE #pending',
        ConditionExpression: '#status = :active AND ((#pending.#id = :id AND #pending.#expiry > :now) OR (#consent.#id = :id AND (attribute_not_exists(#consent.#expiry) OR #consent.#expiry > :now)))',
        ExpressionAttributeNames: {
          '#status': 'status', '#consent': 'billConsent', '#pending': 'pendingBillConsent', '#id': 'id', '#expiry': 'expiresAt',
        },
        ExpressionAttributeValues: { ':active': 'active', ':id': id, ':now': now, ':granted': { id } },
      }));
      return true;
    } catch (e) {
      if (e instanceof ConditionalCheckFailedException) return false;
      throw e;
    }
  }

  async findConnectionsByItemId(itemId: string) {
    const items = await this.queryAll({ index: 'gsi1', key: 'gsi1pk', value: `ITEM#${itemId}` });
    return items.map(DynamoStore.toConnection);
  }
}
