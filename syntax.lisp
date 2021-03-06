(in-package :lem)

(export '(syntax-table
          make-syntax-table))

(defvar *string-color* *green*)
(defvar *comment-color* *red*)

(defstruct (syntax-table (:constructor make-syntax-table-internal))
  (space-chars '(#\space #\tab #\newline))
  (symbol-chars '(#\_))
  (paren-alist '((#\( . #\))
                 (#\[ . #\])
                 (#\{ . #\})))
  (string-quote-chars '(#\" #\'))
  (escape-chars '(#\\))
  expr-prefix-chars
  line-comment-preceding-char
  line-comment-following-char
  block-comment-preceding-char
  block-comment-following-char
  keywords)

(defun make-syntax-table (&rest args)
  (let ((syntax-table (apply #'make-syntax-table-internal args)))
    (setf (syntax-table-keywords syntax-table)
          (mapcar #'(lambda (elt)
                      (cons (cl-ppcre:create-scanner (car elt))
                            (cdr elt)))
                  (syntax-table-keywords syntax-table)))
    syntax-table))

(defun syntax-word-char-p (c)
  (and (characterp c)
       (alphanumericp c)))

(defun syntax-space-char-p (c)
  (member c (syntax-table-space-chars (current-syntax))))

(defun syntax-symbol-char-p (c)
  (or (syntax-word-char-p c)
      (member c (syntax-table-symbol-chars (current-syntax)))))

(defun syntax-open-paren-char-p (c)
  (assoc c (syntax-table-paren-alist (current-syntax))))

(defun syntax-closed-paren-char-p (c)
  (rassoc c (syntax-table-paren-alist (current-syntax))))

(defun syntax-pair-open-paren (c)
  (car (rassoc c (syntax-table-paren-alist (current-syntax)))))

(defun syntax-pair-closed-paren (c)
  (cdr (assoc c (syntax-table-paren-alist (current-syntax)))))

(defun syntax-parallel-paren (c)
  (or (syntax-pair-open-paren c)
      (syntax-pair-closed-paren c)))

(defun syntax-equal-paren-p (x y)
  (flet ((f (c)
            (if (syntax-open-paren-char-p c)
                c
                (syntax-pair-open-paren c))))
    (eql (f x) (f y))))

(defun syntax-string-quote-char-p (c)
  (member c (syntax-table-string-quote-chars (current-syntax))))

(defun syntax-escape-char-p (c)
  (member c (syntax-table-escape-chars (current-syntax))))

(defun syntax-expr-prefix-char-p (c)
  (member c (syntax-table-expr-prefix-chars (current-syntax))))

(defun equal-comment-p (a b x y)
  (and (eql a x)
       (or (null b)
           (eql b y))))

(defun syntax-line-comment-p (c1 c2)
  (equal-comment-p
   (syntax-table-line-comment-preceding-char (current-syntax))
   (syntax-table-line-comment-following-char (current-syntax))
   c1
   c2))

(defun syntax-start-block-comment-p (c1 c2)
  (equal-comment-p
   (syntax-table-block-comment-preceding-char (current-syntax))
   (syntax-table-block-comment-following-char (current-syntax))
   c1
   c2))

(defun syntax-end-block-comment-p (c1 c2)
  (syntax-start-block-comment-p c2 c1))

(defun syntax-scan-window (window)
  (let* ((buffer (window-buffer window))
         (start-linum (window-vtop-linum window))
         (end-linum (+ start-linum (window-nlines window)))
         (line (buffer-get-line buffer start-linum))
         (prev (line-prev line))
         (in-string-p (and prev
                           (or (line-start-string-p prev)
                               (line-in-string-p prev))))
         (in-comment-p (and prev
                            (or (line-start-comment-p prev)
                                (line-in-comment-p prev)))))
    (do ((line line (line-next line))
         (linum start-linum (1+ linum)))
        ((or (null line)
             (= linum end-linum)))
      (multiple-value-setq (in-string-p in-comment-p)
                           (syntax-scan-line line
                                             in-string-p
                                             in-comment-p)))))

(defun parallel-string-quote (line)
  (do ((line #1=(line-prev line) #1#))
      ((null line))
    (when (line-start-string-p line)
      (let* ((str (line-str line))
             (len (length str))
             (prop (line-get-property line (1- len))))
        (do ((pos (- len 2) (1- pos)))
            (nil)
          (when (or (not (eq prop (line-get-property line pos)))
                    (< pos 0))
            (return-from parallel-string-quote
              (schar str (1+ pos)))))))))

(defun syntax-scan-string (line col multiple-lines-p parallel-char)
  (let ((str (line-str line))
        (start-col col))
    (do ((i col (1+ i)))
        ((>= i (length str))
         (line-put-property line start-col i *string-color*)
         (return (values i nil)))
      (let ((c (schar str i)))
        (cond ((syntax-escape-char-p c)
               (incf i))
              ((and (syntax-string-quote-char-p c)
                    (eql c (if (not multiple-lines-p)
                               parallel-char
                               (parallel-string-quote line))))
               (line-put-property line
                                  start-col
                                  (1+ i)
                                  *string-color*)
               (return (values i t))))))))

(defun syntax-scan-block-comment (line col)
  (let ((str (line-str line))
        (start-col col))
    (do ((i1 col i2)
         (i2 (1+ col) (1+ i2)))
        ((>= i2 (length str))
         (line-put-property line start-col i2 *comment-color*)
         (values i2 nil))
      (let ((c1 (schar str i1))
            (c2 (schar str i2)))
        (cond ((syntax-escape-char-p c1)
               (incf i1)
               (incf i2))
              ((syntax-end-block-comment-p c1 c2)
               (line-put-property line
                                  start-col
                                  (1+ i2)
                                  *comment-color*)
               (return (values i2 t))))))))

(defun syntax-match-word (line start end)
  (let ((elt
         (find (subseq (line-str line) start end)
               (syntax-table-keywords (current-syntax))
               :test #'(lambda (a b)
                         (cl-ppcre:scan b a))
               :key #'car)))
    (when elt
      (line-put-property line start end (cdr elt)))))

(defun syntax-scan-word (line start)
  (let* ((str (line-str line))
         (c (schar str start)))
    (cond ((or (syntax-open-paren-char-p c)
               (syntax-closed-paren-char-p c))
           (syntax-match-word line start (1+ start))
           start)
          (t
           (let ((end
                  (do ((i start (1+ i)))
                      ((>= i (length str)) i)
                    (unless (syntax-symbol-char-p (schar str i))
                      (return i)))))
             (syntax-match-word line start end)
             end)))))

(defun syntax-scan-whitespaces (str i)
  (do ((i i (1+ i)))
      ((or (>= i (length str))
           (not (syntax-space-char-p (schar str i))))
       i)))

(defun syntax-scan-line (line in-string-p in-comment-p)
  (setf (line-props line) nil)
  (let ((start-col 0))
    (cond (in-string-p
           (multiple-value-bind (i found-term-p)
               (syntax-scan-string line 0 t nil)
             (cond (found-term-p
                    (setf (line-end-string-p line) t))
                   (t
                    (setf (line-in-string-p line) t)
                    (return-from syntax-scan-line
                      (values t nil))))
             (setq start-col (1+ i))))
          (in-comment-p
           (multiple-value-bind (i found-term-p)
               (syntax-scan-block-comment line 0)
             (cond (found-term-p
                    (setf (line-end-comment-p line) t))
                   (t
                    (setf (line-in-comment-p line) t)
                    (return-from syntax-scan-line
                      (values nil t))))
             (setq start-col (1+ i)))))
    (line-clear-stat line)
    (let ((str (line-str line)))
      (do ((i start-col (1+ i)))
          ((>= i (length str)))
        (when (<= (length str)
                  (setq i (syntax-scan-whitespaces str i)))
          (return))
        (let ((c (schar str i)))
          (cond ((syntax-escape-char-p c)
                 (incf i))
                ((syntax-string-quote-char-p c)
                 (line-put-property line i (1+ i) *string-color*)
                 (multiple-value-bind (j found-term-p)
                     (syntax-scan-string line (1+ i) nil c)
                   (setq i j)
                   (unless found-term-p
                     (setf (line-start-string-p line) t)
                     (return (values t nil)))))
                ((syntax-start-block-comment-p c (safe-aref str (1+ i)))
                 (line-put-property line i (+ i 2) *comment-color*)
                 (multiple-value-bind (j found-term-p)
                     (syntax-scan-block-comment line (+ i 2))
                   (setq i j)
                   (unless found-term-p
                     (setf (line-start-comment-p line) t)
                     (return (values nil t)))))
                ((syntax-line-comment-p c (safe-aref str (1+ i)))
                 (line-put-property line
                                    i
                                    (length str)
                                    *comment-color*)
                 (return))
                (t
                 (setq i (syntax-scan-word line i)))))))))

(defun syntax-scan-buffer (buffer)
  (let ((in-string-p)
        (in-comment-p))
    (map-buffer #'(lambda (line linum)
                    (declare (ignore linum))
                    (multiple-value-setq (in-string-p in-comment-p)
                                         (syntax-scan-line line
                                                           in-string-p
                                                           in-comment-p)))
                buffer)))
