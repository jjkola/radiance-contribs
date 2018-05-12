#|
 This file is a part of Radiance
 (c) 2014 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:i-ldap)

(defvar *nonce-salt* (make-random-string))

(defun redirect-to-landing (&optional (other #@"/"))
  (let ((landing (or (post/get "landing-page")
                     (session:field 'landing-page)
                     other)))
    (setf (session:field 'landing-page) NIL)
    (redirect landing)))

(defun maybe-save-landing ()
  (let ((landing (if (string= (post/get "landing-page") "REFERER")
                     (referer *request*)
                     (or* (post/get "landing-page")))))
    (when landing (setf (session:field 'landing-page) landing))))

(define-api auth/login (username password) ()
  (when (auth:current) (error 'api-error :message "You are already logged in."))
  (let ((user (user:get username)))
    (unless user (error 'auth::invalid-password))
    (auth::check-password user password)
    (auth:associate user)
    (if (string= "true" (post/get "browser"))
        (redirect-to-landing (if (admin:implementation) #@"admin/" #@"/"))
        (api-output "Login successful."))))

(define-api auth/logout () ()
  (session:end)
  (api-output "Logged out."))

(define-api auth/change-password (old-password new-password &optional repeat) (:access (perm auth change-password))
  (let ((user (auth:current NIL)))
    (unless user (error 'api-error :message "You are not logged in."))
    (unless (<= 8 (length new-password))
      (error 'api-error "Password must be 8 characters or more."))
    (unless (or (not repeat) (string= new-password repeat))
      (error 'api-error "The confirmation does not match the password."))
    (auth::check-password user old-password)
    (auth::set-password user new-password)
    (api-output "Password changed.")))

(define-api auth/request-recovery (username) ()
  (when (auth:current) (error 'api-error :message "You are already logged in."))
  (let ((user (user:get username)))
    (unless (and user (mail:implementation))
      (error 'api-error :message "Recovery is not possible at this time."))
    (let ((code (auth::create-recovery user)))
      (mail:send (user:field "email" user)
                 (config :account :recovery :subject)
                 (format NIL (config :account :recovery :message)
                         username (uri-to-url "/api/auth/recover"
                                              :representation :external
                                              :query `(("browser" . "true")
                                                       ("username" . ,username)
                                                       ("code" . ,code)))))
      (if (string= "true" (post/get "browser"))
          (redirect #@"auth/recover")
          (api-output "Recovery email sent.")))))

(define-api auth/recover (username code) ()
  (when (auth:current) (error 'api-error :message "You are already logged in."))
  (let ((user (user:get username)))
    (unless user
      (error 'api-error :message "Invalid username or code."))
    (let ((new-pw (auth::recover user code)))
      (auth:associate user)
      (if (string= "true" (post/get "browser"))
          (redirect-to-landing (if (admin:implementation)
                                   (multiple-value-bind (uri query fragment)
                                       (resource :admin :page "settings" "password")
                                     (uri-to-url uri
                                                 :representation :external
                                                 :query `(("password" . ,new-pw)
                                                          ,@query)
                                                 :fragment fragment))
                                   (uri-to-url "auth/recover"
                                               :representation :external
                                               :query `(("password" . ,new-pw)))))
          (api-output new-pw)))))

(define-page login "auth/login" (:clip "login.ctml")
  (maybe-save-landing)
  (if (auth:current)
      (redirect-to-landing)
      (r-clip:process T)))

(define-page logout "auth/logout" ()
  (session:end)
  (redirect-to-landing))

(define-page register "auth/register" (:clip "register.ctml")
  (maybe-save-landing)
  (ecase (config :account :registration)
    (:closed (r-clip:process T))
    (:open
     (with-actions (error info)
         ((:register
           (handler-bind ((error #'invoke-debugger))
             (r-ratify:with-form
                 (((:string 1 32) username)
                  ((:email 1 32) email)
                  ((:string 8 64) password repeat)
                  (:nonce firstname))
               (declare (ignore firstname))
               (when (user:get username)
                 (error "Sorry, the username is already taken."))
               (when (string/= password repeat)
                 (error "The passwords do not match!"))
               (let ((user (user::create username)))
                 (setf (user:field "email" user) email)
                 (auth::set-password user password)
                 (auth:associate user)
                 (redirect-to-landing))))))
       (let ((nonce (make-random-string)))
         (setf (session:field :nonce-hash) (cryptos:pbkdf2-hash nonce *nonce-salt*)
               (session:field :nonce-salt) *nonce-salt*)
         (r-clip:process
          T :msg (or error info)
            :user (auth:current)
            :nonce nonce))))))

(define-page recover "auth/recover" (:clip "recover.ctml")
  (r-clip:process
   T :password (post/get "password")
     :user (auth:current)))

(define-implement-trigger admin
  (admin:define-panel settings password (:access (perm auth change-password)
                                         :clip "settings.ctml"
                                         :icon "fa-key"
                                         :tooltip "Change your login password.")
    (r-clip:process T)))