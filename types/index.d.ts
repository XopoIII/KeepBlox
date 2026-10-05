// roblox-ts declarations for KeepBlox. They follow src/ exactly; tests/unit/Typings.luau fails when a
// method of Store or Profile is missing here.

declare namespace KeepBlox {
	type EndReason = "released" | "handedOver" | "lost" | "shutdown";

	type LoadFailure =
		| "cancelled"
		| "closing"
		| "timeout"
		| "foreign"
		| "outbid"
		| "inUse"
		| "legacyLocked"
		| "open"
		| "newerSchema"
		| "migration"
		| "schema";

	interface Connection {
		readonly connected: boolean;
		disconnect(): void;
	}

	interface Signal<T extends unknown[]> {
		connect(listener: (...args: T) => void): Connection;
	}

	interface Profile<T extends object> {
		Data: T;
		LastSavedData: T;
		UserIds: number[];
		RobloxMetaData: Record<string, unknown>;
		readonly key: string;
		readonly loadCount: number;
		readonly createdAt: number;
		readonly onSaving: Signal<[final: boolean, reason?: EndReason]>;
		readonly onSaved: Signal<[saved: T]>;
		readonly onEnded: Signal<[reason: EndReason]>;
		isActive(): boolean;
		save(): boolean;
		release(): void;
		onMessage(handler: (message: unknown, processed: () => void) => void): void;
		addUserId(userId: number): void;
		removeUserId(userId: number): void;
	}

	type LoadResult<T extends object> = { ok: true; profile: Profile<T> } | { ok: false; reason: LoadFailure };

	interface LoadOptions {
		cancel?: () => boolean;
		steal?: boolean;
		quiet?: boolean;
	}

	interface Version {
		version: string;
		at: number;
		deleted: boolean;
	}

	interface VersionQuery {
		from?: number;
		to?: number;
		newestFirst?: boolean;
		limit?: number;
	}

	/** `purchasesSince`: purchase ids granted after the version, which the restored data no longer holds. */
	type Restored =
		| { ok: true; purchasesSince: string[] }
		| { ok: false; reason: "inUse" | "notAProfile" | "failed" };
	type Sent = { ok: true } | { ok: false; reason: "full" | "foreign" | "failed" };
	type EditResult<T> = { ok: true; data: T } | { ok: false; reason: LoadFailure | "error" | "refused" | "failed"; message?: string };
	type TradeResult = { ok: true } | { ok: false; reason: "notHere" | "error" | "refused" | "lost" | "failed"; message?: string };

	interface Receipt {
		PlayerId: number;
		PurchaseId: string;
		ProductId: number;
	}

	type ReceiptDecision = "PurchaseGranted" | "NotProcessedYet";

	interface ReceiptOptions<T extends object> {
		keyFor: (userId: number) => string;
		products: Record<number, (profile: Profile<T>, receipt: Receipt) => void>;
		history?: number;
	}

	interface LeaderboardEntry {
		key: string;
		value: number;
	}

	interface Store<T extends object> {
		readonly name: string;
		readonly onError: Signal<[key: string, message: string]>;
		load(key: string, options?: LoadOptions): LoadResult<T>;
		profiles(): Record<string, Profile<T>>;
		message(key: string, message: object): Sent;
		versions(key: string, query?: VersionQuery): Version[];
		readVersion(key: string, version: string): T | undefined;
		restore(key: string, version: string): Restored;
		receipts(options: ReceiptOptions<T>): (receipt: Receipt) => ReceiptDecision;
		edit(key: string, edit: (data: T) => void, options?: { cancel?: () => boolean }): EditResult<T>;
		close(): void;
		trade(keyA: string, keyB: string, change: (dataA: T, dataB: T) => void): TradeResult;
		leaderboard(name: string, query?: { count?: number; ascending?: boolean }): LeaderboardEntry[];
	}

	interface Importer {
		readonly name: string;
	}

	interface ImporterOptions {
		store?: string;
		scope?: string;
		key?: (key: string) => string;
		convert?: (data: unknown) => object;
		lockSeconds?: number;
	}

	/** A step up, or a step up and back down (for a release that can be rolled back). */
	type Migration = ((data: any) => unknown) | { up: (data: any) => unknown; down: (data: any) => unknown };

	interface StoreOptions<T extends object> {
		template?: T;
		schema?: SchemaNode;
		version?: number;
		migrations?: Record<number, Migration>;
		/** The version data is stored at; below `version`, the release can be rolled back. */
		writeVersion?: number;
		config?: ConfigOverrides;
		mock?: boolean | string;
		reconcile?: boolean;
		studio?: "live" | "memory" | "copy";
		import?: Importer;
		leaderboards?: Record<string, (data: T) => number | undefined>;
		leaderboardOptions?: { interval?: number; cache?: number };
		compress?: { above: number };
	}

	interface SharedOptions<T extends object> {
		template?: T;
		schema?: SchemaNode;
		mock?: boolean | string;
		config?: ConfigOverrides;
	}

	type SharedResult<T> = { ok: true; data: T } | { ok: false; reason: "error" | "refused" | "foreign" | "locked" | "failed"; message?: string };

	interface SharedStore<T extends object> {
		readonly name: string;
		/** Studio cannot reach live data, so the documents are kept in memory: once, with the key "". */
		readonly onError: Signal<[key: string, message: string]>;
		read(key: string): SharedResult<T>;
		update(key: string, change: (data: T) => void): SharedResult<T>;
		watch(key: string, handler: (data: T) => void): { Disconnect(): void };
	}

	interface Defaults {
		renew: number;
		death: number;
		profileStoreSteal: number;
		profileStoreDead: number;
		loadTimeout: number;
		callTimeout: number;
		backoffMin: number;
		backoffMax: number;
		writeBytesPerMinute: number;
		shutdownDeadline: number;
		heartbeat: number;
		renewFallback: number;
		snapshotBytes: number;
		snapshotTtl: number;
	}

	/** The settings as Luau names them: `Config` is every setting, `ConfigOverrides` any of them. */
	type Config = Defaults;
	type ConfigOverrides = Partial<Defaults>;

	interface SchemaNode {
		readonly kind: string;
	}

	interface SchemaOptions {
		default?: unknown;
		min?: number;
		max?: number;
		integer?: boolean;
		maxLength?: number;
	}

	interface Schema {
		number(options?: SchemaOptions): SchemaNode;
		string(options?: SchemaOptions): SchemaNode;
		boolean(options?: SchemaOptions): SchemaNode;
		buffer(options?: SchemaOptions): SchemaNode;
		enum(values: string[], options?: SchemaOptions): SchemaNode;
		record(fields: Record<string, SchemaNode>, options?: SchemaOptions): SchemaNode;
		array(item: SchemaNode, options?: SchemaOptions): SchemaNode;
		map(item: SchemaNode, options?: SchemaOptions): SchemaNode;
		optional(item: SchemaNode): SchemaNode;
		any(options?: SchemaOptions): SchemaNode;
	}

	interface Importers {
		DocumentService(options: ImporterOptions): Importer;
		Lapis(options: ImporterOptions): Importer;
		DataKeep(options: ImporterOptions): Importer;
		Suphi(options: ImporterOptions & { decode?: (value: unknown, metadata: Record<string, unknown>) => unknown }): Importer;
		DataStore2(
			options: ImporterOptions & {
				name: string;
				userId: (key: string) => number | undefined;
				method?: "OrderedBackups" | "Standard";
			},
		): Importer;
		custom(importer: {
			name: string;
			read: (value: unknown, keyInfo: DataStoreKeyInfo | undefined, now: number) => unknown;
			fetch?: (services: unknown, key: string) => LuaTuple<[unknown, DataStoreKeyInfo | undefined]>;
		}): Importer;
	}
}

interface KeepBlox {
	store<T extends object>(name: string, options: KeepBlox.StoreOptions<T>): KeepBlox.Store<T>;
	shared<T extends object>(name: string, options: KeepBlox.SharedOptions<T>): KeepBlox.SharedStore<T>;
	readonly defaults: KeepBlox.Defaults;
	readonly schema: KeepBlox.Schema;
	readonly importers: KeepBlox.Importers;
	migrate(
		options: { schema?: KeepBlox.SchemaNode; version?: number; migrations?: Record<number, KeepBlox.Migration> },
		data: unknown,
		from: number,
	): { ok: true; data: unknown; changed: boolean } | { ok: false; reason: "newerSchema" | "migration" | "schema"; message: string };
	migrateDown(
		options: { schema?: KeepBlox.SchemaNode; version?: number; migrations?: Record<number, KeepBlox.Migration> },
		data: unknown,
		to: number,
	): { ok: true; data: unknown } | { ok: false; message: string };
	processReceipt<T extends object>(
		store: KeepBlox.Store<T>,
		options: KeepBlox.ReceiptOptions<T>,
	): (receipt: ReceiptInfo) => Enum.ProductPurchaseDecision;
}

declare const KeepBlox: KeepBlox;
export = KeepBlox;
