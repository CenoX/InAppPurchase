//
//  PaymentProvider.swift
//  InAppPurchase
//
//  Created by Jin Sasaki on 2017/04/06.
//  Copyright © 2017年 Jin Sasaki. All rights reserved.
//

import Foundation
import StoreKit

protocol PaymentQueue {
    static func canMakePayments() -> Bool
    func add(_ observer: SKPaymentTransactionObserver)
    func remove(_ observer: SKPaymentTransactionObserver)

    func add(_ payment: SKPayment)
    func restoreCompletedTransactions()
    func finishTransaction(_ transaction: SKPaymentTransaction)
    var transactions: [SKPaymentTransaction] { get }
}

final internal class PaymentProvider: NSObject {

    private let paymentQueue: PaymentQueue
    private let productIds: [String]?
    private let shouldCompleteImmediately: Bool
    private var paymentHandlers: [String: [PaymentHandler]] = [:]
    private var restoreHandlers: [RestoreHandler] = []
    private var fallbackHandler: PaymentHandler?
    private var shouldAddStorePaymentHandler: ShouldAddStorePaymentHandler?
    private var storePaymentHandler: PaymentHandler?
    private lazy var dispatchQueue: DispatchQueue = DispatchQueue(label: String(describing: self))

    init(paymentQueue: PaymentQueue = SKPaymentQueue.default(),
         shouldCompleteImmediately: Bool,
         productIds: [String]?) {
        self.paymentQueue = paymentQueue
        self.shouldCompleteImmediately = shouldCompleteImmediately
        self.productIds = productIds
    }
}

extension PaymentProvider: PaymentProvidable {
    internal func canMakePayments() -> Bool {
        return type(of: paymentQueue).canMakePayments()
    }

    internal func addTransactionObserver() {
        paymentQueue.add(self)
    }

    internal func removeTransactionObserver() {
        paymentQueue.remove(self)
    }

    internal func add(payment: SKPayment, handler: @escaping PaymentHandler) {
        if let productIds = self.productIds, !productIds.contains(payment.productIdentifier) {
            handler(self.paymentQueue, .failure(InAppPurchase.Error.invalid(productIds: [payment.productIdentifier])))
            return
        }
        addPaymentHandler(withProductIdentifier: payment.productIdentifier, handler: handler)
        DispatchQueue.main.async {
            self.paymentQueue.add(payment)
        }
    }

    internal func addPaymentHandler(withProductIdentifier productIdentifier: String, handler: @escaping PaymentHandler) {
        dispatchQueue.async {
            var handlers: [PaymentHandler] = self.paymentHandlers[productIdentifier] ?? []
            handlers.append(handler)
            self.paymentHandlers[productIdentifier] = handlers
        }
    }

    internal func restoreCompletedTransactions(handler: @escaping RestoreHandler) {
        dispatchQueue.async {
            self.restoreHandlers.append(handler)
            DispatchQueue.main.async {
                self.paymentQueue.restoreCompletedTransactions()
            }
        }
    }

    internal func set(fallbackHandler: @escaping PaymentHandler) {
        dispatchQueue.async {
            self.fallbackHandler = fallbackHandler
        }
    }

    internal func set(shouldAddStorePaymentHandler: @escaping ShouldAddStorePaymentHandler) {
        self.shouldAddStorePaymentHandler = shouldAddStorePaymentHandler
    }
}

extension PaymentProvider: SKPaymentTransactionObserver {
    internal func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            if let productIds = self.productIds, !productIds.contains(transaction.payment.productIdentifier) {
                // Do not handle not registered product
                continue
            }
            switch transaction.transactionState {
            case .purchasing:
                // Do nothing and skip
                continue
            case  .deferred:
                break
            case .purchased, .restored:
                if self.shouldCompleteImmediately {
                    queue.finishTransaction(transaction)
                }
            case .failed:
                queue.finishTransaction(transaction)
            @unknown default:
                // Do nothing and skip
                continue
            }

            dispatchQueue.async {
                if let handlers = self.paymentHandlers.removeValue(forKey: transaction.payment.productIdentifier), !handlers.isEmpty {
                    DispatchQueue.main.async {
                        handlers.forEach({ $0(queue, .success(transaction)) })
                    }
                } else {
                    let handler = self.fallbackHandler
                    DispatchQueue.main.async {
                        handler?(queue, .success(transaction))
                    }
                }
            }
        }
    }

    internal func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        dispatchQueue.async {
            let handlers = self.restoreHandlers
            self.restoreHandlers = []
            DispatchQueue.main.async {
                handlers.forEach({ $0(queue, nil) })
            }
        }
    }

    internal func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        dispatchQueue.async {
            let handlers = self.restoreHandlers
            self.restoreHandlers = []
            DispatchQueue.main.async {
                handlers.forEach({ $0(queue, InAppPurchase.Error(error: error)) })
            }
        }
    }

    internal func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
        return shouldAddStorePaymentHandler?(queue, payment, product) ?? false
    }

    internal func finish(transaction: PaymentTransaction) {
        paymentQueue.finishTransaction(transaction.skTransaction)
    }

    internal var transactions: [PaymentTransaction] {
        paymentQueue.transactions.map(PaymentTransaction.init(_:))
    }
}

// MARK: - SKPaymentQueue extension

extension SKPaymentQueue: PaymentQueue {
    func canMakePayments() -> Bool {
        return SKPaymentQueue.canMakePayments()
    }
}
