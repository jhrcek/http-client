{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

{-
Copyright (c) 2002, Warrick Gray
Copyright (c) 2002-2005, Ian Lynagh
Copyright (c) 2003-2006, Bjorn Bringert
Copyright (c) 2004, Andre Furtado
Copyright (c) 2004-2005, Dominic Steinitz
Copyright (c) 2007, Robin Bate Boerop
Copyright (c) 2008-2010, Sigbjorn Finne
Copyright (c) 2009, Eric Kow
Copyright (c) 2010, Antoine Latter
Copyright (c) 2004, 2010-2011, Ganesh Sittampalam
Copyright (c) 2011, Duncan Coutts
Copyright (c) 2011, Matthew Gruen
Copyright (c) 2011, Jeremy Yallop
Copyright (c) 2011, Eric Hesselink
Copyright (c) 2011, Yi Huang
Copyright (c) 2011, Tom Lokhorst
Copyright (c) 2017, Vassil Keremidchiev

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * The names of contributors may not be used to endorse or promote
      products derived from this software without specific prior
      written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-}

module Network.HTTP.Proxy(  ProxyProtocol(..), EnvHelper(..),
                            systemProxyHelper, envHelper,
                            httpProtocol,
                            ProxySettings ) where

import           Control.Applicative         ((<$>), (<|>))
import           Control.Arrow               (first)
import           Control.Monad               (guard)
import qualified Data.ByteString.Char8       as S8
import           Data.Char                   (toLower)
import qualified Data.Map                    as Map
import qualified Data.Text                   as T
import           Data.Text.Read              (decimal)
import           Network.HTTP.Client.Request (applyBasicProxyAuth,
                                              extractBasicAuthInfo)
import           Network.HTTP.Client.Types   (HttpExceptionContent (..),
                                              Proxy (..), Request (..),
                                              throwHttp)
import qualified Network.URI                 as U
import           System.Environment          (getEnvironment)

#if defined(mingw32_HOST_OS)
import           Control.Exception           (IOException, bracket, catch)
import           Control.Monad               (join, liftM, mplus, when)
import           Data.List                   (isPrefixOf)
import           Foreign                     (Storable (peek, sizeOf), alloca,
                                              castPtr, toBool)
import           Network.URI                 (parseAbsoluteURI)
import           Safe                        (readDef)
import           System.IO
import           System.Win32.Registry       (hKEY_CURRENT_USER, regCloseKey,
                                              regOpenKey, regQueryValue,
                                              regQueryValueEx)
import           System.Win32.Types          (DWORD, HKEY)
#endif

type EnvName     = T.Text
type HostAddress = S8.ByteString
type UserName    = S8.ByteString
type Password    = S8.ByteString

-- There are other proxy protocols like SOCKS, FTP, etc.
data ProxyProtocol = HTTPProxy | HTTPSProxy deriving Show

data ProxySettings = ProxySettings { proxyHost :: Proxy,
                                     proxyAuth :: Maybe (UserName, Password) }

httpProtocol :: Bool -> ProxyProtocol
httpProtocol True  = HTTPSProxy
httpProtocol False = HTTPProxy

data EnvHelper = EHFromRequest
               | EHNoProxy
               | EHUseProxy Proxy

headJust :: [Maybe a] -> Maybe a
headJust []               = Nothing
headJust (Nothing:xs)     = headJust xs
headJust ((y@(Just x)):_) = y

systemProxyHelper :: ProxyProtocol -> EnvHelper -> IO (Request -> Request)
systemProxyHelper prot eh = do
    modifier <- envHelper . envName $ prot

-- Under Windows try first env. variables override then Windows proxy settings
#if defined(mingw32_HOST_OS)
    modifier' <- systemProxy prot
    let modifiers = [modifier, modifier']
#else
    let modifiers = [modifier]
#endif

    let chooseMod :: Request -> Maybe ProxySettings
        chooseMod req = headJust . map (\m -> m . host $ req) $ modifiers

        noEnvProxy = case eh of
            EHFromRequest -> id
            EHNoProxy     -> \req -> req { proxy = Nothing }
            EHUseProxy p  -> \req -> req { proxy = Just p  }

    let result req = toRequest . chooseMod $ req where
            toRequest Nothing                            = noEnvProxy req
            toRequest (Just (ProxySettings p muserpass)) = maybe id (uncurry applyBasicProxyAuth) muserpass
                                        req { proxy = Just p }
    pure result


#if defined(mingw32_HOST_OS)
windowsProxyString :: IO (Maybe String)
windowsProxyString = liftM (>>= parseWindowsProxy) registryProxyString

registryProxyLoc :: (HKEY,String)
registryProxyLoc = (hive, path)
  where
    -- some sources say proxy settings should be at
    -- HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows
    --                   \CurrentVersion\Internet Settings\ProxyServer
    -- but if the user sets them with IE connection panel they seem to
    -- end up in the following place:
    hive  = hKEY_CURRENT_USER
    path = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

-- read proxy settings from the windows registry; this is just a best
-- effort and may not work on all setups.
registryProxyString :: IO (Maybe String)
registryProxyString = catch
  (bracket (uncurry regOpenKey registryProxyLoc) regCloseKey $ \hkey -> do
    enable <- fmap toBool $ regQueryValueDWORD hkey "ProxyEnable"
    if enable
        then fmap Just $ regQueryValue hkey (Just "ProxyServer")
        else return Nothing)
  hideError where
      hideError :: IOException -> IO (Maybe String)
      hideError _ = return Nothing

-- the proxy string is in the format "http=x.x.x.x:yyyy;https=...;ftp=...;socks=..."
-- even though the following article indicates otherwise
-- https://support.microsoft.com/en-us/kb/819961
--
-- to be sure, parse strings where each entry in the ';'-separated list above is
-- either in the format "protocol=..." or "protocol://..."
--
-- only return the first "http" of them, if it exists
parseWindowsProxy :: String -> Maybe String
parseWindowsProxy s =
  case proxies of
    x:_ -> Just x
    _   -> Nothing
  where
    parts = split ';' s
    pr x = case break (== '=') x of
      (p, []) -> p  -- might be in format http://
      (p, u)  -> p ++ "://" ++ drop 1 u

    proxies = filter (isPrefixOf "http://") . map pr $ parts

    split :: Eq a => a -> [a] -> [[a]]
    split _ [] = []
    split a xs = case break (a ==) xs of
      (ys, [])   -> [ys]
      (ys, _:zs) -> ys:split a zs

-- Extract proxy settings from Windows registry. This is a standard way in Windows OS.
systemProxy :: ProxyProtocol -> IO (HostAddress -> Maybe ProxySettings)
systemProxy _ = do
    proxy <- fetchProxy False
    return $ const proxy

-- | @fetchProxy flg@ gets the local proxy settings and parse the string
-- into a @Proxy@ value. If you want to be informed of ill-formed proxy
-- configuration strings, supply @True@ for @flg@.
-- Proxy settings are sourced from IE/WinInet's proxy
-- setting in the Registry.
fetchProxy :: Bool -> IO (Maybe ProxySettings)
fetchProxy warnIfIllformed = do
    mstr <- windowsProxyString
    case mstr of
      Nothing     -> return Nothing
      Just str    -> case parseProxy str of
          it@(Just p) -> return it
          Nothing     -> do
              when warnIfIllformed $ System.IO.hPutStrLn System.IO.stderr $ unlines
                      [ "invalid http proxy uri: " ++ show str
                      , "proxy uri must be http with a hostname"
                      , "ignoring http proxy, trying a direct connection"
                      ]
              return Nothing

-- | @parseProxy str@ translates a proxy server string into a @Proxy@ value;
-- returns @Nothing@ if not well-formed.
parseProxy :: String -> Maybe ProxySettings
parseProxy str = join
                 . fmap uri2proxy
                 $ parseHttpURI str
                 `mplus` parseHttpURI ("http://" ++ str)
    where
     parseHttpURI str' =
      case parseAbsoluteURI str' of
        Just uri@U.URI{U.uriAuthority = Just{}} -> Just (fixUserInfo uri)
        _                                       -> Nothing

       -- Note: we need to be able to parse non-URIs like @\"wwwcache.example.com:80\"@
       -- which lack the @\"http://\"@ URI scheme. The problem is that
       -- @\"wwwcache.example.com:80\"@ is in fact a valid URI but with scheme
       -- @\"wwwcache.example.com:\"@, no authority part and a path of @\"80\"@.
       --
       -- So our strategy is to try parsing as normal uri first and if it lacks the
       -- 'uriAuthority' then we try parsing again with a @\"http://\"@ prefix.
       --

-- | @dropWhileTail p ls@ chops off trailing elements from @ls@
-- until @p@ returns @False@.
dropWhileTail :: (a -> Bool) -> [a] -> [a]
dropWhileTail f ls =
    case foldr chop Nothing ls of { Just xs -> xs; Nothing -> [] }
     where
       chop x (Just xs) = Just (x:xs)
       chop x _
        | f x       = Nothing
        | otherwise = Just [x]

-- | @chopAtDelim elt ls@ breaks up @ls@ into two at first occurrence
-- of @elt@; @elt@ is elided too. If @elt@ does not occur, the second
-- list is empty and the first is equal to @ls@.
chopAtDelim :: Eq a => a -> [a] -> ([a],[a])
chopAtDelim elt xs =
    case break (==elt) xs of
    (_,[])    -> (xs,[])
    (as,_:bs) -> (as,bs)

-- | tidy up user portion, don't want the trailing "\@".
fixUserInfo :: U.URI -> U.URI
fixUserInfo uri = uri{ U.uriAuthority = f `fmap` U.uriAuthority uri }
    where
     f a@U.URIAuth{U.uriUserInfo=s} = a{U.uriUserInfo=dropWhileTail (=='@') s}

defaultHTTPport = 80 :: Int

uri2proxy :: U.URI -> Maybe ProxySettings
uri2proxy uri@U.URI{
              U.uriScheme    = "http:"
            , U.uriAuthority = Just (U.URIAuth auth' hst prt)
          } =
    Just (ProxySettings (Proxy (S8.pack hst) (port prt)) auth)
    where
     port (':':xs) = readDef defaultHTTPport xs
     port _        = defaultHTTPport

     auth =
       case auth' of
         [] -> Nothing
         as -> Just ((S8.pack . U.unEscapeString $ usr), (S8.pack . U.unEscapeString $ pwd))
          where
           (usr,pwd) = chopAtDelim ':' as

uri2proxy _ = Nothing

regQueryValueDWORD :: HKEY -> String -> IO DWORD
regQueryValueDWORD hkey name = alloca $ \ptr -> do
  -- TODO: this throws away the key type returned by regQueryValueEx
  -- we should check it's what we expect instead
  _ <- regQueryValueEx hkey name (castPtr ptr) (sizeOf (undefined :: DWORD))
  peek ptr

#endif

envName :: ProxyProtocol -> EnvName
envName HTTPProxy  = "http_proxy"
envName HTTPSProxy = "https_proxy"

-- Extract proxy settings from environment variables. This is a standard way in Linux.
envHelper :: EnvName -> IO (HostAddress -> Maybe ProxySettings)
envHelper name = do
  env <- getEnvironment
  let lenv = Map.fromList $ map (first $ T.toLower . T.pack) env
      lookupEnvVar n = lookup (T.unpack n) env <|> Map.lookup n lenv
      noProxyDomains = domainSuffixes (lookupEnvVar "no_proxy")

  case lookupEnvVar name of
      Nothing  -> return . const $ Nothing
      Just ""  -> return . const $ Nothing
      Just str -> do
          let invalid = throwHttp $ InvalidProxyEnvironmentVariable name (T.pack str)
          (p, muserpass) <- maybe invalid return $ do
              let allowedScheme x = x == "http:"
              uri <- case U.parseURI str of
                  Just u | allowedScheme (U.uriScheme u) -> return u
                  _      -> U.parseURI $ "http://" ++ str

              guard $ allowedScheme $ U.uriScheme uri
              guard $ null (U.uriPath uri) || U.uriPath uri == "/"
              guard $ null $ U.uriQuery uri
              guard $ null $ U.uriFragment uri

              auth <- U.uriAuthority uri
              port' <-
                  case U.uriPort auth of
                      "" -> Just 80
                      ':':rest ->
                          case decimal $ T.pack rest of
                              Right (p, "") -> Just p
                              _             -> Nothing
                      _ -> Nothing

              Just (Proxy (S8.pack $ U.uriRegName auth) port', extractBasicAuthInfo uri)
          return $ \hostRequest ->
              if hostRequest `hasDomainSuffixIn` noProxyDomains
              then Nothing
              else Just $ ProxySettings p muserpass
  where prefixed s | S8.head s == '.' = s
                   | otherwise = S8.cons '.' s
        domainSuffixes Nothing = []
        domainSuffixes (Just "") = []
        domainSuffixes (Just no_proxy) = [prefixed $ S8.dropWhile (== ' ') suffix | suffix <- S8.split ',' (S8.pack (map toLower no_proxy)), not (S8.null suffix)]
        hasDomainSuffixIn host' = any (`S8.isSuffixOf` prefixed (S8.map toLower host'))
