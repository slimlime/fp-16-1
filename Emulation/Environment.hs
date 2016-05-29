{-# LANGUAGE ScopedTypeVariables #-}

module Environment (Cell(..), getIntFromCell, getInstructionFromCell, getStringFromCell, 
					Environment, eA, eSP, ePC, eRAM, eStaticSize, eStdIn, eStdOut, eSymTable, initEnvF, eThawEnv, freezeEnv, makeEnvFromAss) where

import Data.Array
import Data.Array.IO
import Data.List

import Assembly
import SymbolTable
import ABR.Parser
import ABR.Parser.Lexers

-- the number of cells, indexed from 0,
memSize :: Int
memSize = 20

data Cell = 
	  Undefined
	| Int Int
	| Inst Instruction
	deriving Show

getIntFromCell :: Cell -> Int
getIntFromCell (Int a) = a

getInstructionFromCell :: Cell -> Instruction
getInstructionFromCell (Inst x) = x

getStringFromCell :: Cell -> String
getStringFromCell cell = case cell of
	Int c -> show c
	Inst c -> convertInstToString c
	_ -> ""

data Environment = Environment {
		eA :: Cell,
		eSP :: Int,
		ePC :: Int,
		eRAM :: Either (IOArray Int Cell) (Array Int Cell),
		eStaticSize :: Int, -- the number of cells filled up by the ass prog, where the heap would start
		eStdIn :: [Int],
		eStdOut :: [Int],
		eSymTable :: SymbolTable
	}
   
instance Show Environment where
  showsPrec _ e = 
	let 
		Right r = eRAM e
	in 
		showString "ENVIRONMENT [" .
		showString "\n   A = " . shows (eA e) .
		showString "\n   SP = " . shows (eSP e) .
		showString "\n   PC = " . shows (ePC e) .
		showString "\n   StdIn = " . shows (eStdIn e) .
		showString "\n   StdOut = " . shows (eStdOut e) .
		showString "\n   SstaticSize = " . shows (eStaticSize e) .
		showString "\n   RAM = " . (showString (concat (intersperse "\n         " (map getStringFromCell (elems r))))) .
		showString "\n   Symbols = " . shows (eSymTable e) .
		showString "\n]\n" 
	
initEnvF :: Environment
initEnvF = Environment {
		eA = Undefined,
		eSP = memSize,
		ePC = 0,
		eRAM = Right $ listArray (0, memSize - 1) (repeat Undefined),
		eStaticSize = 0,
		eStdIn = [],
		eStdOut = [],
		eSymTable = emptyST
   }
   
eThawEnv :: Environment -> IO Environment
eThawEnv e = do
	let Right r = eRAM e
	r' <- thaw r
	return $ e {eRAM = Left r'}
   
freezeEnv :: Environment -> IO Environment
freezeEnv e = do
	let Left r = eRAM e
	r' <- freeze r
	return $ e {eRAM = Right r'}

makeEnvFromAss :: String -> IO Environment
makeEnvFromAss source = do
	prog <- parseAss source
   
	st <- buildST prog
	st' <-resolveST prog st
	st'' <-verifyST prog st'
	
	let inst = stripInstructions prog
	let stdIn = [5]

	let env = initEnvF {eSP = memSize, eSymTable = st'', eStdIn = stdIn}
	env' <- eThawEnv env

	addInstToEnv inst 0 env'
   
	return env'
   
addInstToEnv :: [Instruction] -> Int -> Environment -> IO Environment
addInstToEnv xs index env = case xs of
	[] -> return env
	(x:xs') -> let
			Left ram = (eRAM env)
		in do
			writeArray ram index (Inst x)
			addInstToEnv xs' (index+1) env
	
parseAss :: String -> IO Program
parseAss source = do
   let cps = preLex source
   let lexRes = (dropWhite $ nofail $ total assemblyL) cps
   case lexRes of
      Error _ _    -> error "LEXER FAILED"
      OK (tlps, _) -> do
         let parseRes = (nofail $ total programP) tlps
         case parseRes of
            Error _ _     -> error "PARSER FAILED"
            OK (program, _) -> do
				return program	
   
stripInstructions :: Program -> [Instruction]
stripInstructions (Program decl) = case decl of
	[] -> []
	(x:xs) -> case x of 
		DcLH p l -> stripInstructions (Program xs)
		DcLB p l -> stripInstructions (Program xs)
		DcAlloc p a -> stripInstructions (Program xs)
		DcInst p i -> [i] ++ stripInstructions (Program xs)
		DcVal p v -> stripInstructions (Program xs)
		
convertInstToString :: Instruction -> String
convertInstToString inst = case inst of
	MOVE _ s d -> "MOVE " ++ convertSrcToString s ++ " " ++ convertDestToString d
	ADD _ s d -> "ADD " ++ convertSrcToString s ++ " " ++ convertDestToString d
	SUB _ s d -> "SUB " ++ convertSrcToString s ++ " " ++ convertDestToString d
	MULT _ s d -> "MULT " ++ convertSrcToString s ++ " " ++ convertDestToString d
	DIV _ s d -> "DIV " ++ convertSrcToString s ++ " " ++ convertDestToString d
	MOD _ s d -> "MOD " ++ convertSrcToString s ++ " " ++ convertDestToString d
	JUMP _ v -> "JUMP " ++ convertValueToString v
	CALL _ v -> "CALL " ++ convertValueToString v
	BEQ _ v -> "BEQ " ++ convertValueToString v
	BNE _ v -> "BNE " ++ convertValueToString v
	BLT _ v -> "BLT " ++ convertValueToString v
	BGT _ v -> "BGT " ++ convertValueToString v
	BLE _ v -> "BLE " ++ convertValueToString v
	BGE _ v -> "BGE " ++ convertValueToString v
	RET _ -> "RETURN"
	HALT _ -> "HALT"
	
convertDestToString :: Dest -> String
convertDestToString dest = case dest of
	DRegister _ r -> convertRegToString r
	DValue _ v -> convertValueToString v
	DIndex _ l v -> "(" ++ convertLocationToString l ++ ")" ++ convertValueToString v
	DPostInc _ l -> "(" ++ convertLocationToString l ++ ")+"
	DPostDec _ l -> "(" ++ convertLocationToString l ++ ")-"
	DPreInc _ l -> "+(" ++ convertLocationToString l ++ ")"
	DPreDec _ l -> "-(" ++ convertLocationToString l ++ ")"
	DIndirect _ l -> "(" ++ convertLocationToString l ++ ")"
	
convertSrcToString :: Source -> String
convertSrcToString src = case (sVal src) of
	Left x -> convertDestToString x	--Dest
	Right x -> "#" ++ convertValueToString x	--Value
	
convertLocationToString :: Location -> String
convertLocationToString loc = case (lLoc loc) of
	Left x -> convertRegToString x	--Reg
	Right x -> convertValueToString x	--Value
	
convertRegToString :: Register -> String
convertRegToString reg = rVal reg
	
convertValueToString :: Value -> String
convertValueToString value = case (vVal value) of
	Left x -> (idName x)	--Indentifier
	Right x -> show (uiVal x)	--Uint