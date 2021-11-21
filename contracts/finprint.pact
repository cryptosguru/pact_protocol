(define-keyset 'admin-keyset (read-keyset "admin-keyset"))

(module finprint GOVERNANCE

  @doc " 'finprint' implements the core Finprint protocol. This contract \
       \ provides functions to create and manage lockboxes and requests to \
       \ read the data inside those lockboxes. A lockbox holds a unit of data \
       \ involving two parties: the 'writer', who writes the data and attests \
       \ to its validity; and the 'consumer', whom the data is about, and who \
       \ may determine with whom the data may be shared. In the case where the \
       \ data represents something which may change over time, the writer may \
       \ update the lockbox with new data, creating multiple lockbox versions. \
       \ \
       \ Because all payments are denominated in stablecoin, parties are \
       \ generally referenced throughout the contract by means of an account \
       \ ID, denoting an account on the stablecoin contract. Accounts on the \
       \ finprint-token contract are used for staking purposes, and are \
       \ denoted by the suffix 'FptAccountId'. "

  ; ----------------------------------------------------------------------------
  ; Constants

  (defconst MIN_TIME:time (time "0000-01-01T00:00:00Z")
    " Timestamp smaller than all feasible timestamps. ")
  (defconst MAX_TIME:time (time "9999-01-01T00:00:00Z")
    " Timestamp larger than all feasible timestamps. ")

  (defconst ROW_KEY_SEPARATOR:string stablecoin-example.ACCOUNT_ID_PROHIBITED_CHARACTER
    " String to use as a separator for compound database keys. ")

  (defconst SHARING_FEE_FRACTION:decimal 0.25
    " Sharing fee fraction. \
    \ \
    \ Each lockbox has a price, which the reader must pay upon opening a request. \
    \ The sharing fee fraction denotes a fraction of the price to be split equally \
    \ among the sharing nodes. The rest of the price goes to the writer. \
    \ \
    \ Note that when a lockbox owner reads their own lockbox they receive a \
    \ discount, and only pay the sharing fee. ")

  (defconst LOCKBOX_DEPOSIT_MULTIPLE:decimal 3.0
    " Sharing fee fraction. \
    \ \
    \ Each lockbox has a deposit, which every sharing node must put in before  \
    \ joining a sharing group. A reader that wins a challenge against a sharing \
    \ node receives the deposit as the prize. The deposit is a multiple of the price. \
    \ \
    \ The sharing node can reclaim their deposit after leaving a lockbox if they \
    \ have not forfeited it to any reader. ")

  (defconst ESCROW_ACCOUNT_ID 'FINPRINT_ESCROW
    " Account ID for stablecoins held in escrow. \
    \ \
    \ We store everything in a single escrow account to avoid having to create \
    \ account IDs on the fly which could collide with existing IDs. ")

  (defconst PENDING_VERSION_EXPIRATION_S 86400.0
    " Specifies the amount of time (in seconds) after a pending version is \
    \ added to a lockbox, after which, if it is not acknowledged by all \
    \ sharing nodes, it may be removed from the lockbox. This allows \
    \ sharing nodes to reclaim their lockbox deposits in case a pending \
    \ version is set by the writer but is neither approved nor updated. ")

  (defconst LEAVE_LOCKBOX_RESPONSE_DEADLINE_S 604800.0
    " Specifies the amount of time (in seconds) after a sharing node calls \
    \ initiate-leave-lockbox that a writer has to satisfy the request by \
    \ updating the lockbox with a new sharing group. \
    \ \
    \ If the deadline is exceeded without the request being satisfied, then \
    \ the sharing node may call force-leave-lockbox, deactivating the lockbox. \
    \ \
    \ Currently set arbitrarily to one week. ")

  (defconst CHALLENGE_DEADLINE_S 604800.0
    " Period of time (in seconds) after a request is opened after which it can \
    \ no longer be challenged. \
    \ Currently set arbitrarily to one week. ")

  (defconst POST_RESULT_DEADLINE_S 3600.0
    " Period of time (in seconds) after a request is opened, within which all \
    \ sharing nodes are required to post their results, in order to avoid \
    \ being penalized. \
    \ Currently set arbitrarily to one hour. ")

  (defconst STAKE_THRESHOLD 1000000.0
    " Min balance that a sharing node must stake in order to be added to a \
    \ lockbox sharing group. ")

  ; ----------------------------------------------------------------------------
  ; Schemas and Tables

  (defschema lockbox-schema
    @doc " A lockbox, containing a unit of data written by a writer about a consumer. \
         \ \
         \ ROW KEY: lockboxId "
    writerAccountId:string ; The lockbox writer, who has the ability to update the lockbox content.
    owner:guard ; AKA the “consumer.” Denotes capability to add and remove readers. Also receives a discounted read price.
    currentVersionId:string ; The current version of the lockbox
    pendingVersionId:string ; The most recently proposed version of the lockbox
    pendingVersionAddedAt:time ; The time at which the pending version was last set
  )
  (deftable lockbox-table:{lockbox-schema})

  (defschema lockbox-version-schema
    @doc " The mutable fields of a lockbox that can be changed through updates. \
         \ certain lockbox. \
         \ \
         \ ROW KEY: versionId "
    protocolVersion:integer
    price:decimal ; Total cost to read the lockbox.
    lockboxDepositAmount:decimal ; Required deposit per sharing group member, denoted in stablecoin.
    secretSharesCid:string ; Finprint content ID pointing to the encrypted shares of the content.
    sharingGroup:[string] ; Account IDs of the sharing nodes, who have the ability to post results.
  )
  (deftable lockbox-version-table:{lockbox-version-schema})

  (defschema share-hash-schema
    @doc " The hash of the secret share provided to a sharing node for a \
         \ certain lockbox. \
         \ \
         \ ROW KEY: `{versionId}{ROW_KEY_SEPARATOR}{sharingNodeAccountId}` "
    shareHash:string
    acknowledged:bool
  )
  (deftable share-hash-table:{share-hash-schema})

  (defschema reader-auth-schema
    @doc " A record indicating authorization or lack of authorization for a \
         \ reader to read a particular lockbox. A lockbox by default provides \
         \ no access, and each reader must be explicitly authorized. \
         \ \
         \ ROW KEY: `{lockboxId}{ROW_KEY_SEPARATOR}{readerAccountId}` "
    authorized:bool ; Whether or not the reader is authorized to read the lockbox.
  )
  (deftable reader-auth-table:{reader-auth-schema})

  (defschema request-schema
    @doc " A request made by an authorized reader to read a lockbox. \
         \ \
         \ ROW KEY: requestId "
    protocolVersion:integer ; The protocol version of the lockbox at the time the request was opened.
    lockboxId:string ; The lockbox ID for the lockbox for which this request was opened.
    versionId:string ; The version ID for the lockbox for which this request was opened.
    readerAccountId:string ; The account ID of the reader who opened the request.
    requestPublicKey:string ; The RSA public key to be used to encrypt the results.
    price:decimal ; The lockbox price at the time the request was opened.
    secretSharesCid:string ; The secret shares CID at the time the request was opened.
    sharingGroup:[string] ; The lockbox sharing group at the time the request was opened.
    openedAt:time ; The time at which the request was opened
  )
  (deftable request-table:{request-schema})

  (defschema result-schema
    @doc " A share of the lockbox secret encrypted and published in response to a request. \
         \ \
         \ ROW KEY: '{requestId}{ROW_KEY_SEPARATOR}{sharingNodeAccountId}' "
    ciphertext:string
    nonce:string
    mac:string
  )
  (deftable result-table:{result-schema})

  (defschema challenge-schema
    @doc " A record of challenges that have occurred. \
         \ \
         \ ROW KEY: '{requestId}-{sharingNodeAccountId}' "
    wasChallenged:bool
  )
  (deftable challenge-table:{challenge-schema})

  (defschema sharing-node-activity-schema
    @doc " Tracks sharing node activity on a lockbox. \
         \ \
         \ ROW KEY: `{lockboxId}{ROW_KEY_SEPARATOR}{sharingNodeAccountId}` "
    lastRequestOpenedAt:time
    leaveRequestInitiatedAt:time
  )
  (deftable sharing-node-activity-table:{sharing-node-activity-schema})

  (defschema sharing-node-membership-schema
    @doc " Tracks information about the participation of a sharing node as a \
         \ member of lockbox sharing groups. This information is used to \
         \ determine whether the account is allowed to withdraw its staked \
         \ tokens. \
         \ \
         \ ROW KEY: sharingNodeAccountId "
    lockboxCount:integer
  )
  (deftable sharing-node-membership-table:{sharing-node-membership-schema})

  (defschema stake-schema
    @doc " Mapping from an account ID to a stake account ID. \
         \ \
         \ ROW KEY: stakeOwnerAccountId "
    stakeFptAccountId:string
  )
  (deftable stake-table:{stake-schema})

  (defschema lockbox-deposit-schema
    @doc " Mapping from an account ID to group member's lockbox deposit. \
         \ \
         \ ROW KEY: {lockboxId}{ROW_KEY_SEPARATOR}{sharingNodeAccountId} "
    depositAccountId:string
  )
  (deftable lockbox-deposit-table:{lockbox-deposit-schema})

  ; ----------------------------------------------------------------------------
  ; Capabilities

  (defcap GOVERNANCE
    ()

    @doc " Give the admin full access to call and upgrade the module. "

    (enforce-keyset 'admin-keyset)
  )

  (defcap INTERNAL
    ()

    @doc " Generic capability guarding functions which should only be invoked \
         \ from within this module. "

    true
  )

  (defcap AUTHORIZE_READER
    ( lockboxId:string )

    @doc " Capability to bestow or revoke authorization to read a lockbox. "

    (with-read lockbox-table lockboxId
      { "owner" := owner }
      (enforce-guard owner)
    )
  )

  (defcap READ_LOCKBOX
    ( lockboxId:string readerAccountId:string )

    @doc " Capability to open a request to read a lockbox. "

    (with-read lockbox-table lockboxId
      { "owner" := owner }
      (with-default-read reader-auth-table (compound-key lockboxId readerAccountId)
        { "authorized" : false }
        { "authorized" := authorized }
        (enforce-one
          "Not authorized to read the lockbox."
          [(enforce authorized "") (enforce-guard owner)]
        )
      )
    )
  )

  (defcap WITHDRAW_ESCROW
    ()

    @doc " Capability to move funds out of escrow. "

    true
  )

  (defcap WITHDRAW_STAKE
    ( stakeOwnerAccountId:string )

    @doc " Capability to move funds out of a stake account. \
         \ Note that accountId represents the account ID of the stake holder, \
         \ which is distinct from the stake account ID itself. "

    true
  )

  (defcap WITHDRAW_LOCKBOX_DEPOSIT
    ( lockboxId:string
      sharingNodeAccountId:string )

    @doc " Capability to move funds out of a group member's lockbox deposit account. \
         \ Note that accountId represents the account ID of the group member, \
         \ which is distinct from the deposit account ID. "

    true
  )

  ; ----------------------------------------------------------------------------
  ; Guards

  (defun escrow-guard:bool
    ()

    @doc " Used to limit access to the escrow account. \
         \ \
         \ Requires that the caller obtain the WITHDRAW_ESCROW capability \
         \ before attempting to withdraw funds. "

    (require-capability (WITHDRAW_ESCROW))
  )

  (defun stake-guard
    ( accountId:string )

    @doc " Used to limit access to stake accounts. \
         \ \
         \ Requires that the caller obtain the WITHDRAW_STAKE capability \
         \ before attempting to withdraw funds. This ensures that stake \
         \ funds can only be withdrawn via the `decrease-stake` function. "

    (require-capability (WITHDRAW_STAKE accountId))
  )

  (defun lockbox-deposit-guard
    ( lockboxId:string
      accountId:string )

    @doc " Used to limit access to group deposit accounts. \
         \ \
         \ Requires that the caller obtain the WITHDRAW_LOCKBOX_DEPOSIT \
         \ capability before attempting to withdraw funds. "

    (require-capability (WITHDRAW_LOCKBOX_DEPOSIT lockboxId accountId))
  )

  ; ----------------------------------------------------------------------------
  ; Internal Helper Functions

  (defun enforce-account-guard:bool
    ( accountId:string )

    @doc " Enforce the guard for a stablecoin account. "

    (enforce-guard (at 'guard (stablecoin-example.details accountId)))
  )

  (defun iterable-not-contains:bool
    ( array:[string]
      element:string )

    (require-capability (INTERNAL))
    (not (contains element array))
  )

  (defun compound-key:string
    ( part1:string
      part2:string )

    @doc " Helper function to create two-part row keys. "

    (require-capability (INTERNAL))
    (format "{}{}{}" [part1 ROW_KEY_SEPARATOR part2])
  )

  (defun result-exists:bool
    ( requestId:string
      sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-default-read result-table (compound-key requestId sharingNodeAccountId)
      { "ciphertext" : "" }
      { "ciphertext" := ciphertext }

      (!= ciphertext "")
    )
  )

  (defun check-if-acknowledged:bool
    ( versionId:string
      sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-read share-hash-table (compound-key versionId sharingNodeAccountId)
      { "acknowledged" := acknowledged }
      acknowledged
    )
  )

  (defun append-if-unique:[string]
    ( strs:[string]
      str:string )

    (require-capability (INTERNAL))
    (if (contains str strs) strs (+ strs [str]))
  )

  (defun enforce-lockbox-requirements:bool
    ( writerAccountId:string
      versionId:string
      price:decimal
      sharingGroup:[string] )

    (require-capability (INTERNAL))
    (enforce-account-guard writerAccountId)
    (map (stablecoin-example.get-balance) sharingGroup) ; Enforce accounts exist.
    (enforce (!= versionId "") "Version ID cannot be empty.")
    (enforce (> price 0.0) "The price must be positive.")
    (enforce (> (length sharingGroup) 0) "The sharing group cannot be empty.")
    (enforce (> (sharing-node-fee price sharingGroup) 0.0) "The sharing node fee must be positive.")
    (enforce
      (= (length sharingGroup) (length (fold (append-if-unique) [] sharingGroup)))
      "All sharing nodes must have different accounts."
    )
    (map (enforce-staked) sharingGroup)
  )

  (defun result-matches-hash:bool
    ( versionId:string
      requestId:string
      publicKey:string
      privateKey:string
      sharingNodeAccountId:string )

    @doc " Helper function for challenge-result. Returns true if the result \
         \ posted by the sharing node matches the hash posted by the writer. "

    (require-capability (INTERNAL))
    (with-read share-hash-table (compound-key versionId sharingNodeAccountId)
      { "shareHash" := shareHash }

      (with-read result-table (compound-key requestId sharingNodeAccountId)
        { "ciphertext" := ciphertext
        , "nonce"      := nonce
        , "mac"        := mac }

        ; Decrypt the result to reveal the share of the secret.
        (let
          (
            ; Note: This can return a match if decryption fails and the hash provided by the writer was an empty string.
            (decryptedResultHash (try "" (hash (base64-decode (decrypt-cc20p1305 ciphertext nonce "" mac publicKey privateKey)))))
          )
          (= decryptedResultHash shareHash)
        )
      )
    )
  )

  (defun increment-lockbox-count
    ( sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-default-read sharing-node-membership-table sharingNodeAccountId
      { "lockboxCount" : 0 }
      { "lockboxCount" := lockboxCount }
      (write sharing-node-membership-table sharingNodeAccountId
        { "lockboxCount" : (+ lockboxCount 1 ) }
      )
    )
  )

  (defun decrement-lockbox-count
    ( sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-read sharing-node-membership-table sharingNodeAccountId
      { "lockboxCount" := lockboxCount }

      (enforce (> lockboxCount 0) "cannot decrement since count is zero")

      (update sharing-node-membership-table sharingNodeAccountId
        { "lockboxCount" : (- lockboxCount 1 ) }
      )
    )
  )

  (defun update-last-request-opened-at
    ( lockboxId:string
      sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-default-read sharing-node-activity-table (compound-key lockboxId sharingNodeAccountId)
      { "leaveRequestInitiatedAt" : MIN_TIME }
      { "leaveRequestInitiatedAt" := leaveRequestInitiatedAt }
      (write sharing-node-activity-table (compound-key lockboxId sharingNodeAccountId)
        { "lastRequestOpenedAt"     : (at 'block-time (chain-data))
        , "leaveRequestInitiatedAt" : leaveRequestInitiatedAt }
      )
    )
  )

  (defun reset-leave-lockbox
    ( lockboxId: string
      accountId: string )

    @doc " Clear a sharing node's request to leave a lockbox. "

    (require-capability (INTERNAL))
    (with-default-read sharing-node-activity-table (compound-key lockboxId accountId)
      { "lastRequestOpenedAt" : MIN_TIME }
      { "lastRequestOpenedAt" := lastRequestOpenedAt }
      (write sharing-node-activity-table (compound-key lockboxId accountId)
        { "lastRequestOpenedAt"     : lastRequestOpenedAt
        , "leaveRequestInitiatedAt" : MAX_TIME }
      )
    )
  )

  (defun mark-challenged
    ( requestId:string
      sharingNodeAccountId:string )

    (require-capability (INTERNAL))
    (with-default-read challenge-table (compound-key requestId sharingNodeAccountId)
      { "wasChallenged" : false }
      { "wasChallenged" := wasChallenged }
      (enforce
        (not wasChallenged)
        "Result was already challenged."
      )
      (write challenge-table (compound-key requestId sharingNodeAccountId)
        { "wasChallenged" : true }
      )
    )
  )

  (defun store-share-hash:object
    ( versionId:string
      acc:object
      _:bool )

    (require-capability (INTERNAL))
    (bind acc
      { "sharingGroup" := sharingGroup
      , "shareHashes"  := shareHashes }

      (let
        ( (sharingNodeAccountId (at 0 sharingGroup))
          (shareHash (at 0 shareHashes)) )

        (write share-hash-table (compound-key versionId sharingNodeAccountId)
          { "shareHash"    : shareHash
          , "acknowledged" : false }
        )
      )

      { "sharingGroup" : (drop 1 sharingGroup)
      , "shareHashes"  : (drop 1 shareHashes) }
    )
  )

  (defun update-lockbox-current-version:string
    ( lockboxId:string )

    @doc " Promote the pending version to the new current version of a lockbox. "

    (require-capability (INTERNAL))
    (with-read lockbox-table lockboxId
      { "currentVersionId"  := currentVersionId
      , "pendingVersionId"  := pendingVersionId }

      (with-default-read lockbox-version-table currentVersionId
        { "sharingGroup": [] } { "sharingGroup" := oldSharingGroup }

        (with-read lockbox-version-table pendingVersionId
          { "protocolVersion" := protocolVersion
          , "price"           := price
          , "secretSharesCid" := secretSharesCid
          , "sharingGroup"    := newSharingGroup }

          (let*
            ( (removedSharingNodes
                (filter (iterable-not-contains newSharingGroup) oldSharingGroup)) )

            (map (enforce-staked) newSharingGroup)
            (map (increment-lockbox-count) newSharingGroup)
            (map (decrement-lockbox-count) oldSharingGroup)
            (map (reset-leave-lockbox lockboxId) removedSharingNodes)
            (update lockbox-table lockboxId
              { "currentVersionId" : pendingVersionId
              , "pendingVersionId" : "" }
            )
            "Lockbox current version updated."
          )
        )
      )
    )
  )

  (defun slash:string
    ( requestId:string
      sharingNodeAccountId:string )

    @doc " Penalize a sharing node by giving their lockbox deposit to the \
         \ reader who opened a request. Should be called when a reader \
         \ issues a successful challenge. "

    (require-capability (INTERNAL))
    (with-read request-table requestId
      { "lockboxId"        := lockboxId
      , "readerAccountId"  := readerAccountId }

      (with-read lockbox-table lockboxId
        { "currentVersionId" := currentVersionId }

        (with-read lockbox-version-table currentVersionId
          { "lockboxDepositAmount" := lockboxDepositAmount }

          (with-capability (WITHDRAW_LOCKBOX_DEPOSIT lockboxId sharingNodeAccountId)
            (stablecoin-example.transfer
              (get-lockbox-deposit-account-id lockboxId sharingNodeAccountId)
              readerAccountId
              lockboxDepositAmount
            )
          )
        )
      )
    )
  )

  ; ----------------------------------------------------------------------------
  ; Fee Calculation Helper Functions

  (defun sharing-node-fee:decimal
    ( price:decimal
      sharingGroup:[string] )

    @doc " The fee to be paid to each sharing node in the sharing group. "

    (floor (/ (* price SHARING_FEE_FRACTION) (length sharingGroup)) 0)
  )

  (defun sharing-node-fee-for-request:decimal
    ( requestId:string )

    @doc " The fee to be paid to each sharing node in the sharing group. "

    (with-read request-table requestId
      { "price"        := price
      , "sharingGroup" := sharingGroup
      }
      (sharing-node-fee price sharingGroup)
    )
  )

  (defun writer-fee-for-request:decimal
    ( requestId:string )

    @doc " The fee to be paid to the writer. "

    (with-read request-table requestId
      { "price"        := price
      , "sharingGroup" := sharingGroup
      }
      (- price (* (sharing-node-fee-for-request requestId) (length sharingGroup)))
    )
  )

  ; ----------------------------------------------------------------------------
  ; External Functions - Lockbox Deposits

  (defun allow-withdraw-lockbox-deposit:bool
    ( lockboxId:string
      sharingNodeAccountId:string )

    @doc " Determines whether a sharing node is permitted to withdraw their \
         \ lockbox deposit. "

    (with-default-read sharing-node-activity-table (compound-key lockboxId sharingNodeAccountId)
      { "lastRequestOpenedAt" : MIN_TIME }
      { "lastRequestOpenedAt" := lastRequestOpenedAt }

      (with-read lockbox-table lockboxId
        { "currentVersionId" := currentVersionId
        , "pendingVersionId" := pendingVersionId }

        (with-default-read lockbox-version-table currentVersionId
          { "sharingGroup" : [] }
          { "sharingGroup" := currentGroup }

          ; Note that pendingVersionId may be the empty string, in which case `acknowledged`
          ; is required to be false.
          (with-default-read share-hash-table (compound-key pendingVersionId sharingNodeAccountId)
            { "acknowledged" : false}
            { "acknowledged" := acknowledgedPendingVersion }

            (let
              ( (currentTime (at 'block-time (chain-data)))
                (challengeDeadline (add-time lastRequestOpenedAt CHALLENGE_DEADLINE_S)) )

              (and
                (> currentTime challengeDeadline)
                (not
                  (or
                    (contains sharingNodeAccountId currentGroup)
                    acknowledgedPendingVersion
                  )
                )
              )
            )
          )
        )
      )
    )
  )

  (defun get-lockbox-deposit-account-id:string
    ( lockboxId:string
      sharingNodeAccountId: string )

    @doc " Get the lockbox deposit account ID for an account. \
         \ Fails if the account has not created a lockbox deposit. "

    (at 'depositAccountId
      (read lockbox-deposit-table (compound-key lockboxId sharingNodeAccountId) ['depositAccountId])
    )
  )

  (defun create-lockbox-deposit:string
    ( lockboxId:string
      sharingNodeAccountId:string
      lockboxDepositAccountId:string )

    @doc " Create an account to hold the stablecoin deposit for a lockbox. \
         \ The account is created with exactly the lockboxDepositAmount \
         \ specified in the pending lockbox version. \
         \ \
         \ Note that we use the deposit amount from the pending version \
         \ because by the time a version is active, all of its sharing \
         \ group members will already have existing lockbox deposit \
         \ accounts. \
         \ \
         \ This function should only be called by members named in the \
         \ pending version group, but that is not enforced. "

    (enforce-account-guard sharingNodeAccountId)

    (with-capability (INTERNAL)
      (with-read lockbox-table lockboxId
        { "pendingVersionId" := pendingVersionId }
        (with-read lockbox-version-table pendingVersionId
          { "lockboxDepositAmount" := lockboxDepositAmount }

          (stablecoin-example.transfer-create
            sharingNodeAccountId
            lockboxDepositAccountId
            (create-user-guard (lockbox-deposit-guard lockboxId sharingNodeAccountId))
            lockboxDepositAmount
          )
          (insert lockbox-deposit-table (compound-key lockboxId sharingNodeAccountId)
            { "depositAccountId" : lockboxDepositAccountId }
          )
        )
      )
    )
    "Lockbox deposit created."
  )

  (defun withdraw-lockbox-deposit:string
    ( lockboxId:string
      sharingNodeAccountId:string )

    @doc " Transfers a lockbox deposit back to the sharing node who made the \
         \ deposit. "

    (enforce-account-guard sharingNodeAccountId)
    (let*
      ( (lockboxDepositAccountId (get-lockbox-deposit-account-id lockboxId sharingNodeAccountId))
        (depositBalance (stablecoin-example.get-balance lockboxDepositAccountId))
        (withdrawAllowed (allow-withdraw-lockbox-deposit lockboxId sharingNodeAccountId)) )

      (enforce withdrawAllowed
        "Cannot withdraw lockbox deposit since this node is part of a sharing group \
        \or is still subject to potential challenges."
      )
      (with-capability (WITHDRAW_LOCKBOX_DEPOSIT lockboxId sharingNodeAccountId)
        (stablecoin-example.transfer
          lockboxDepositAccountId
          sharingNodeAccountId
          depositBalance
        )
      )
    )
    "Lockbox deposit withdrawn."
  )

  ; ----------------------------------------------------------------------------
  ; External Functions - Staking

  (defun create-stake
    ( stakeOwnerAccountId:string
      senderFptAccountId:string
      stakeFptAccountId:string
      amount:decimal )

    @doc " Create an account to hold staked tokens for an account. \
         \ Will fail if a stake account was already created for this account. "

    (enforce-account-guard stakeOwnerAccountId)

    (insert stake-table stakeOwnerAccountId
      { "stakeFptAccountId" : stakeFptAccountId }
    )

    (finprint-token.transfer-create
      stakeOwnerAccountId
      stakeFptAccountId
      (create-user-guard (stake-guard stakeOwnerAccountId))
      amount
    )
    "Stake created."
  )

  (defun increase-stake:string
    ( stakeOwnerAccountId:string
      senderFptAccountId:string
      amount:decimal )

    @doc " Deposit to a stake account. "

    (finprint-token.transfer
      senderFptAccountId
      (get-stake-fpt-account-id stakeOwnerAccountId)
      amount
    )
  )

  (defun decrease-stake:string
    ( stakeOwnerAccountId:string
      receiverFptAccountId:string
      amount:decimal )

    @doc " Withdraw from a stake account. "

    (enforce-account-guard stakeOwnerAccountId)

    (let*
      ( (oldStake (get-stake stakeOwnerAccountId))
        (newStake (- oldStake amount))
        (unstakeAllowed (allow-withdraw-stake stakeOwnerAccountId)) )

      (enforce
        (or
          (>= newStake STAKE_THRESHOLD)
          unstakeAllowed
        )
        " Cannot decrease stake by that amount since it would leave the account \
        \ below the required threshold while it is still subject to staking \
        \ requirements. "
      )

      (with-capability (WITHDRAW_STAKE stakeOwnerAccountId)
        (finprint-token.transfer
          (get-stake-fpt-account-id stakeOwnerAccountId)
          receiverFptAccountId
          amount
        )
      )
    )
    "Stake decreased."
  )

  (defun allow-withdraw-stake:bool
    ( stakeOwnerAccountId:string )

    @doc " Determines whether an account is permitted to reduce their stake \
         \ below the threshold amount. \
         \ \
         \ Note: This function does not handle the case in which a sharing \
         \ node is in zero lockbox “current versions” but is on one or more \
         \ lockbox “pending versions”. In that case, the sharing node may \
         \ withdraw their stake and the writers of those lockboxes will \
         \ have to propose a new pending version before they can update \
         \ the lockbox. "

    (with-default-read sharing-node-membership-table stakeOwnerAccountId
      { "lockboxCount" : 0 }
      { "lockboxCount" := lockboxCount }
      (= lockboxCount 0)
    )
  )

  (defun enforce-staked:bool
    ( stakeOwnerAccountId:string )

    @doc " Enforce that an account has a stake at least equal to the staking \
         \ threshold. "

    (let ((stakeBalance (get-stake stakeOwnerAccountId)))
      (enforce (>= stakeBalance STAKE_THRESHOLD)
        "The account's stake does not meet the threshold requirement."
      )
    )
  )

  (defun get-stake:decimal
    ( stakeOwnerAccountId: string )

    @doc " Get the staked balance for an account. \
         \ Fails if the account has not created a stake. "

    (with-read stake-table stakeOwnerAccountId
      { "stakeFptAccountId" := stakeFptAccountId }
      (finprint-token.get-balance stakeFptAccountId)
    )
  )

  (defun get-stake-fpt-account-id:string
    ( stakeOwnerAccountId: string )

    @doc " Get the stake account ID for an account. \
         \ Fails if the account has not created a stake. "

    (at 'stakeFptAccountId (read stake-table stakeOwnerAccountId ['stakeFptAccountId]))
  )

  ; ----------------------------------------------------------------------------
  ; External Functions - Lockboxes and Requests

  (defun initialize:string
    ()

    @doc " Initialize the contract. \
         \ Admin-only. Should fail if it has been called before. "

    (with-capability (GOVERNANCE)
      (stablecoin-example.create-account ESCROW_ACCOUNT_ID (create-user-guard (escrow-guard)))
      "Initialized."
    )
  )

  (defun create-lockbox:string
    ( lockboxId:string
      versionId:string
      protocolVersion:integer
      writerAccountId:string
      owner:guard
      price:decimal
      secretSharesCid:string
      sharingGroup:[string]
      shareHashes:[string] )

    @doc " Create a lockbox. "

    (insert lockbox-table lockboxId
      { "writerAccountId"       : writerAccountId
      , "owner"                 : owner
      , "currentVersionId"      : ""
      , "pendingVersionId"      : versionId
      , "pendingVersionAddedAt" : (at 'block-time (chain-data)) }
    )

    (update-lockbox
      lockboxId
      versionId
      protocolVersion
      price
      secretSharesCid
      sharingGroup
      shareHashes
    )
    "Lockbox creation pending."
  )

  (defun update-lockbox:string
    ( lockboxId:string
      versionId:string
      protocolVersion:integer
      price:decimal
      secretSharesCid:string
      newSharingGroup:[string]
      newShareHashes:[string] )

    @doc " Propose a change to the data contained in a lockbox and/or the sharing group. \
         \ When the change is approved by all sharing nodes in the updated lockbox \
         \ version, it is promoted to the current version by the contract. \
         \ \
         \ Note that this must fail if the version ID is the empty string \
         \ since the empty string is a special value for pendingVersionId. "

    (with-capability (INTERNAL)
      (with-read lockbox-table lockboxId
        { "writerAccountId" := writerAccountId }

        (enforce-lockbox-requirements writerAccountId versionId price newSharingGroup)

        (insert lockbox-version-table versionId
          { "protocolVersion"      : protocolVersion
          , "price"                : price
          , "lockboxDepositAmount" : (* LOCKBOX_DEPOSIT_MULTIPLE price)
          , "secretSharesCid"      : secretSharesCid
          , "sharingGroup"         : newSharingGroup
          }
        )

        (update lockbox-table lockboxId
          { "pendingVersionId"      : versionId
          , "pendingVersionAddedAt" : (at 'block-time (chain-data)) }
        )
        (fold
          (store-share-hash versionId)
          { "sharingGroup" : newSharingGroup
          , "shareHashes"  : newShareHashes
          }
          (make-list (length newSharingGroup) true)
        )
      )
      "Lockbox pending version updated."
    )
  )

  (defun add-reader:string
    ( lockboxId:string
      readerAccountId:string )

    @doc " Authorize a reader to read a lockbox. "

    (with-capability (AUTHORIZE_READER lockboxId)
      (write reader-auth-table (compound-key lockboxId readerAccountId)
        { "authorized" : true }
      )
      "Reader added."
    )
  )

  (defun remove-reader:string
    ( lockboxId:string
      readerAccountId:string )

    @doc " Revoke authorization for a reader to read a lockbox. "

    (with-capability (AUTHORIZE_READER lockboxId)
      (write reader-auth-table (compound-key lockboxId readerAccountId)
        { "authorized" : false }
      )
      "Reader removed."
    )
  )

  (defun open-request:string
    ( lockboxId:string
      requestId:string
      readerAccountId:string
      maxPrice:decimal
      requestPublicKey:string )

    @doc " Open a request to read a lockbox. Must have already been authorized \
         \ by the consumer. "

    (enforce-account-guard readerAccountId)

    (with-capability (INTERNAL)
      (with-capability (READ_LOCKBOX lockboxId readerAccountId)
        (with-read lockbox-table lockboxId
          { "currentVersionId" := versionId
          , "owner"            := owner }

          (with-read lockbox-version-table versionId
            { "protocolVersion" := protocolVersion
            , "price"           := price
            , "secretSharesCid" := secretSharesCid
            , "sharingGroup"    := sharingGroup }

            ; Require requests to provide a max price to prevent front-running by the writer.
            (enforce (<= price maxPrice) "The lockbox price is above the specified max price.")

            ; If the sharing group is empty, that indicates that the lockbox has
            ; been deactivated. Don't allow requests to be opened.
            (enforce (> (length sharingGroup) 0) "The sharing group is empty.")

            (let
              ( (ownerIsCaller (try false (enforce-guard owner)))
                (sharingGroupFee (* (sharing-node-fee price sharingGroup) (length sharingGroup))) )

              ; Transfer funds to escrow.
              ; The consumer does not have to pay the writer to read their own data.
              (stablecoin-example.transfer
                readerAccountId
                ESCROW_ACCOUNT_ID
                (if ownerIsCaller sharingGroupFee price)
              )

              (insert request-table requestId
                { "protocolVersion"  : protocolVersion
                , "readerAccountId"  : readerAccountId
                , "lockboxId"        : lockboxId
                , "versionId"        : versionId
                , "requestPublicKey" : requestPublicKey
                , "price"            : price
                , "secretSharesCid"  : secretSharesCid
                , "sharingGroup"     : sharingGroup
                , "openedAt"         : (at 'block-time (chain-data))
                }
              )

              (map (update-last-request-opened-at lockboxId) sharingGroup)
              "Request opened."
            )
          )
        )
      )
    )
  )

  (defun acknowledge-share:string
    ( lockboxId:string
      versionId:string
      sharingNodeAccountId:string )

    (enforce-account-guard sharingNodeAccountId)

    (with-capability (INTERNAL)
      (with-read lockbox-table lockboxId
        { "pendingVersionId" := pendingVersionId }
        (enforce (= versionId pendingVersionId) "Version ID is not pending.")

        ; Note: We maintain the invariant that an empty string versionId cannot exist in this table.
        (with-read lockbox-version-table versionId
          { "sharingGroup"         := sharingGroup
          , "lockboxDepositAmount" := lockboxDepositAmount }
          (enforce
            (contains sharingNodeAccountId sharingGroup)
            "Account is not a member of the lockbox sharing group."
          )
          (with-read lockbox-deposit-table (compound-key lockboxId sharingNodeAccountId)
            { "depositAccountId" := depositAccountId }
            (let
              ((depositAccountBalance (stablecoin-example.get-balance depositAccountId)))
              (enforce (= lockboxDepositAmount depositAccountBalance) "Insufficient lockbox deposit.")
            )
          )
          (update share-hash-table (compound-key versionId sharingNodeAccountId)
            { "acknowledged" : true }
          )

          ; Promote the pending version to current if all sharing nodes acknowledged their shares.
          (if (fold (and) true (map (check-if-acknowledged versionId) sharingGroup))
            (update-lockbox-current-version lockboxId)
            "Waiting on other acknowledgements."
          )
        )
      )
    )
  )

  (defun clear-expired-pending-version:string
    ( lockboxId:string )

    @doc " Clear the pending version of a lockbox if it has expired without \
         \ being acknowledged by all sharing nodes. This function may be \
         \ called by anyone. It is needed simply to allow sharing nodes \
         \ to recover their lockbox deposit in case a pending version \
         \ never becomes active and the lockbox is abandoned. "

    (with-read lockbox-table lockboxId
      { "pendingVersionAddedAt" := pendingVersionAddedAt }

      (let
        ( (currentTime (at 'block-time (chain-data)))
          (deadline (add-time pendingVersionAddedAt PENDING_VERSION_EXPIRATION_S)) )

        (enforce
          (> currentTime deadline)
          "The pending version has not yet expired."
        )
      )

      (update lockbox-table lockboxId
        { "pendingVersion" : "" }
      )
    )
  )

  (defun post-result:string
    ( requestId:string
      sharingNodeAccountId:string
      ciphertext:string
      mac:string
      nonce:string )

    @doc " Called by a sharing node to publish their share, encrypted, in \
         \ response to a request. "

    (enforce-account-guard sharingNodeAccountId)
    (enforce (!= ciphertext "") "Result ciphertext cannot be empty.")
    (enforce (!= mac "") "Result MAC cannot be empty.")
    (enforce (!= nonce "") "Result nonce cannot be empty.")

    (with-capability (INTERNAL)
      (with-read request-table requestId
        { "lockboxId"       := lockboxId
        , "price"           := price
        , "secretSharesCid" := secretSharesCid
        , "sharingGroup"    := sharingGroup
        }

        (enforce
          (contains sharingNodeAccountId sharingGroup)
          "Account is not a member of the lockbox sharing group."
        )

        ; Pay the sharing node.
        (with-capability (WITHDRAW_ESCROW)
          (stablecoin-example.transfer ESCROW_ACCOUNT_ID sharingNodeAccountId
            (sharing-node-fee-for-request requestId))
        )

        ; Insert the result into the result table
        (insert result-table (compound-key requestId sharingNodeAccountId)
          { "ciphertext" : ciphertext
          , "nonce"      : nonce
          , "mac"        : mac
          }
        )

        ; Only pay the writer after all results have been posted.
        (if (fold (and) true (map (result-exists requestId) sharingGroup))
          (with-capability (WITHDRAW_ESCROW)
            (with-read lockbox-table lockboxId
              { "writerAccountId" := writerAccountId
              , "owner"           := owner
              }
              (if (try false (enforce-guard owner))
                "noop" ; consumer does not pay writer when reading their own data
                (stablecoin-example.transfer ESCROW_ACCOUNT_ID writerAccountId (writer-fee-for-request requestId))
              )
            )
          )
          "noop"
        )
        "Result posted."
      )
    )
  )

  (defun challenge-missing-result:string
    ( requestId:string
      sharingNodeAccountId:string )

    @doc " May be called by a reader if a sharing node does not respond to \
         \ their request by the deadline. "

    (mark-challenged requestId sharingNodeAccountId)

    (with-capability (INTERNAL)
      (with-read request-table requestId
        { "readerAccountId" := readerAccountId
        , "sharingGroup"    := sharingGroup
        , "openedAt"        := openedAt }

        (enforce-account-guard readerAccountId)
        (enforce
          (contains sharingNodeAccountId sharingGroup)
          "Account is not a member of the lockbox sharing group.")

        (let
          ( (currentTime (at 'block-time (chain-data)))
            (postResultDeadline (add-time openedAt POST_RESULT_DEADLINE_S))
            (challengeDeadline (add-time openedAt CHALLENGE_DEADLINE_S)) )

          (enforce
            (> currentTime postResultDeadline)
            "The deadline for posting a result has not yet passed."
          )
          (enforce
            (<= currentTime challengeDeadline)
            "The deadline for challenging this request has passed."
          )
        )

        (with-default-read result-table (compound-key requestId sharingNodeAccountId)
          { "ciphertext" : "" }
          { "ciphertext" := ciphertext }

          (enforce
            (= ciphertext "")
            "Challenge failed since a result has been posted."
          )

          (slash requestId sharingNodeAccountId)
        )
      )
    )
    "Result challenged."
  )

  (defun challenge-invalid-result:string
    ( requestId:string
      requestPrivateKey:string
      sharingNodeAccountId:string )

    @doc " May be called by a reader if a sharing node responds to their \
         \ request with an invalid result. "

    (mark-challenged requestId sharingNodeAccountId)

    (with-capability (INTERNAL)
      (with-read request-table requestId
        { "versionId"        := versionId
        , "readerAccountId"  := readerAccountId
        , "requestPublicKey" := requestPublicKey
        , "sharingGroup"     := sharingGroup
        , "openedAt"         := openedAt }

        (enforce-account-guard readerAccountId)
        (enforce
          (contains sharingNodeAccountId sharingGroup)
          "Account is not a member of the lockbox sharing group.")

        (let
          ( (currentTime (at 'block-time (chain-data)))
            (challengeDeadline (add-time openedAt CHALLENGE_DEADLINE_S)) )

          (enforce
            (<= currentTime challengeDeadline)
            "The deadline for challenging this request has passed."
          )
        )

        (if (try false (validate-keypair requestPublicKey requestPrivateKey))
          ; Key pair is valid, so penalize the sharing node if their posted result was invalid.
          (let
            ( (resultIsValid
                (result-matches-hash
                  versionId
                  requestId
                  requestPublicKey
                  requestPrivateKey
                  sharingNodeAccountId)) )
            (enforce
              (not resultIsValid)
              "Challenge failed since the posted result was valid."
            )
            (slash requestId sharingNodeAccountId)
          )

          ; Key pair is invalid. Reader may re-challenge.
          (enforce false "Invalid keypair.")
        )
      )
    )
    "Result challenged."
  )

  (defun initiate-leave-lockbox:string
    ( lockboxId:string
      accountId:string )

    @doc " Called by a sharing node to initiate the process of leaving a lockbox. "

    (enforce-account-guard accountId)

    (with-capability (INTERNAL)
      (with-read lockbox-table lockboxId
        { "currentVersionId" := versionId }
        (with-read lockbox-version-table versionId
          { "sharingGroup" := sharingGroup }
          (enforce
            (contains accountId sharingGroup)
            "Account is not a member of the lockbox sharing group."
          )
        )

        (with-default-read sharing-node-activity-table (compound-key lockboxId accountId)
          { "lastRequestOpenedAt" : MIN_TIME }
          { "lastRequestOpenedAt" := lastRequestOpenedAt }
          (write sharing-node-activity-table (compound-key lockboxId accountId)
            { "lastRequestOpenedAt"     : lastRequestOpenedAt
            , "leaveRequestInitiatedAt" : (at 'block-time (chain-data)) }
          )
        )
        "Leave request initiated."
      )
    )
  )

  (defun force-leave-lockbox
    ( lockboxId:string
      accountId:string )

    @doc " Called by a sharing node after initiating a leave request, if the \
         \ lockbox writer has exceeded the deadline for responding to the \
         \ request. This forces an update to the lockbox removing all sharing \
         \ nodes and causing the lockbox to be deactivated and unable to \
         \ receive new read requests. "

    (with-capability (INTERNAL)
      (with-read lockbox-table lockboxId
        { "currentVersionId" := versionId }
        (with-read sharing-node-activity-table (compound-key lockboxId accountId)
          { "leaveRequestInitiatedAt" := leaveRequestInitiatedAt }

          (let
            ( (currentTime (at 'block-time (chain-data)))
              (deadline (add-time leaveRequestInitiatedAt LEAVE_LOCKBOX_RESPONSE_DEADLINE_S)) )

            (enforce
              (> currentTime deadline)
              "Deadline for writer to respond to leave request not yet exceeded.")
          )
        )

        (with-read lockbox-version-table versionId
          { "sharingGroup" := sharingGroup }
          (enforce
            (contains accountId sharingGroup)
            "Account is not a member of the lockbox sharing group.")

          (update lockbox-version-table versionId { "sharingGroup" : [] })
          (map (decrement-lockbox-count) sharingGroup)
          (map (reset-leave-lockbox lockboxId) sharingGroup)
        )
      )
    )
    "Sharing group reset."
  )

  ; ----------------------------------------------------------------------------
  ; Database Query Helpers (External Use Only)

  (defun get-sharing-node-activity
    ( lockboxId:string
      sharingNodeAccountId:string )

    (with-default-read sharing-node-activity-table (compound-key lockboxId sharingNodeAccountId)
      { "leaveRequestInitiatedAt" : MIN_TIME
      , "lastRequestOpenedAt"     : MIN_TIME
      }
      { "leaveRequestInitiatedAt" := leaveRequestInitiatedAt
      , "lastRequestOpenedAt"     := lastRequestOpenedAt
      }
      { "leaveRequestInitiatedAt" : leaveRequestInitiatedAt
      , "lastRequestOpenedAt"     : lastRequestOpenedAt
      }
    )
  )

  (defun get-sharing-node-membership
    ( sharingNodeAccountId:string )

    (with-default-read sharing-node-membership-table sharingNodeAccountId
      { "lockboxCount" : 0 }
      { "lockboxCount" := lockboxCount }
      lockboxCount
    )
  )
)

(create-table lockbox-table)
(create-table lockbox-version-table)
(create-table share-hash-table)
(create-table request-table)
(create-table result-table)
(create-table challenge-table)
(create-table reader-auth-table)
(create-table sharing-node-activity-table)
(create-table sharing-node-membership-table)
(create-table stake-table)
(create-table lockbox-deposit-table)
