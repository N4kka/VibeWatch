-- Secondo difetto in clip_toggle_comment_like, indipendente dai cast uuid.
--
-- La funzione dichiara `RETURNS TABLE(liked boolean, like_count integer)`: dentro
-- il corpo `like_count` e' una variabile PL/pgSQL. Ma `clip_comments` ha una
-- colonna con lo stesso nome, e l'UPDATE la usava senza qualificarla:
--
--   ERROR 42702: column reference "like_count" is ambiguous
--
-- Quindi anche con i cast a posto ogni like a un commento sarebbe fallito. Il
-- nome delle colonne di ritorno non si puo' cambiare — iOS decodifica
-- `{liked, like_count}` in SupabaseToggleCommentLikeResponse — quindi si
-- qualificano i riferimenti alla tabella con un alias.
CREATE OR REPLACE FUNCTION public.clip_toggle_comment_like(p_comment_id text, p_like_id text)
 RETURNS TABLE(liked boolean, like_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  existing_id uuid;
  v_comment uuid;
  v_new_id uuid;
BEGIN
  IF p_comment_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'clip_toggle_comment_like: p_comment_id non e'' un uuid valido';
  END IF;
  v_comment := p_comment_id::uuid;

  SELECT l.id INTO existing_id
  FROM clip_comment_likes l
  WHERE l.comment_id = v_comment
    AND l.user_id = auth.uid();

  IF existing_id IS NULL THEN
    v_new_id := CASE
      WHEN p_like_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN p_like_id::uuid
      ELSE gen_random_uuid()
    END;

    INSERT INTO clip_comment_likes (id, comment_id, user_id, created_at)
    VALUES (v_new_id, v_comment, auth.uid(), timezone('utc', now()));

    UPDATE clip_comments c
       SET like_count = COALESCE(c.like_count, 0) + 1,
           updated_at = timezone('utc', now())
     WHERE c.id = v_comment;

    RETURN QUERY SELECT TRUE,
                        (SELECT COALESCE(c2.like_count, 0) FROM clip_comments c2 WHERE c2.id = v_comment);
  ELSE
    DELETE FROM clip_comment_likes l WHERE l.id = existing_id;

    UPDATE clip_comments c
       SET like_count = GREATEST(COALESCE(c.like_count, 0) - 1, 0),
           updated_at = timezone('utc', now())
     WHERE c.id = v_comment;

    RETURN QUERY SELECT FALSE,
                        (SELECT COALESCE(c2.like_count, 0) FROM clip_comments c2 WHERE c2.id = v_comment);
  END IF;
END;
$function$;
