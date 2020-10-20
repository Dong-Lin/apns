import Vapor
import struct NIO.TimeAmount

extension Application {
    public var apns: APNS {
        .init(application: self)
    }

    public struct APNS {
        
        struct TimeoutKey: StorageKey {
            typealias Value = TimeAmount
        }
        
        public var customTimeout: TimeAmount {
            get {
                var defaultTimeOut:TimeAmount = .seconds(5)
                if let timeout = self.application.storage[TimeoutKey.self]{
                    defaultTimeOut = timeout
                }
                return defaultTimeOut
            }
            nonmutating set {
                self.application.storage[TimeoutKey.self] = newValue
            }
        }
        
        struct ConfigurationKey: StorageKey {
            typealias Value = APNSwiftConfiguration
        }

        public var configuration: APNSwiftConfiguration? {
            get {
                self.application.storage[ConfigurationKey.self]
            }
            nonmutating set {
                self.application.storage[ConfigurationKey.self] = newValue
            }
        }

        struct PoolKey: StorageKey, LockKey {
            typealias Value = EventLoopGroupConnectionPool<APNSConnectionSource>
        }

        internal var pool: EventLoopGroupConnectionPool<APNSConnectionSource> {
            if let existing = self.application.storage[PoolKey.self] {
                logger?.info("return existing connection pool for apns")
                return existing
            } else {
                let lock = self.application.locks.lock(for: PoolKey.self)
                lock.lock()
                defer { lock.unlock() }
                guard let configuration = self.configuration else {
                    fatalError("APNS not configured. Use app.apns.configuration = ...")
                }
                let new = EventLoopGroupConnectionPool(
                    source: APNSConnectionSource(configuration: configuration),
                    maxConnectionsPerEventLoop: 10,
                    requestTimeout: customTimeout,
                    logger: self.application.logger,
                    on: self.application.eventLoopGroup
                )
                self.application.storage.set(PoolKey.self, to: new) {
                    $0.shutdown()
                }
                logger?.info("create and return new pool")
                return new
            }
        }
        
        public func restartPool() {
            if let existing = self.application.storage[PoolKey.self] {
                logger?.info("Restart pool when error encounter")
                existing.shutdown()
                self.application.storage[PoolKey.self] = nil
            }
        }

        let application: Application
    
    }
}

extension Application.APNS: APNSwiftClient {
    public var logger: Logger? {
        self.application.logger
    }

    public var eventLoop: EventLoop {
        self.application.eventLoopGroup.next()
    }

    public func send(
        rawBytes payload: ByteBuffer,
        pushType: APNSwiftConnection.PushType,
        to deviceToken: String,
        expiration: Date?,
        priority: Int?,
        collapseIdentifier: String?,
        topic: String?,
        logger: Logger?
    ) -> EventLoopFuture<Void> {
        self.application.apns.pool.withConnection(
            logger: logger,
            on: self.eventLoop
        ) {
            $0.send(
                rawBytes: payload,
                pushType: pushType,
                to: deviceToken,
                expiration: expiration,
                priority: priority,
                collapseIdentifier: collapseIdentifier,
                topic: topic,
                logger: logger
            )
        }
    }
}
